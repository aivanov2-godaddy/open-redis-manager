<?php
declare(strict_types=1);

/**
 * Exercise the fixed WHM Redis diagnostic classes through authenticated WHM SSO.
 * Each probe reads normalized metadata only; the harness never prints page bodies or values.
 */

const ORM_CPanel_ROOT = '/usr/local/cpanel';
const ORM_INSTALL_ROOT = '/usr/local/cpanel/3rdparty/orm';

if (in_array('--help', $argv, true)) {
    fwrite(STDOUT, "Usage: php tests/whm-live-diagnostics-form.php --username=ACCOUNT --confirm-live-reads\n"
        . "Requires root on a disposable cPanel & WHM host and one running ORM-managed Redis instance.\n"
        . "Submits eight fixed read-only probes at the account rate limit, then rejects an unsupported class.\n"
        . "Output contains only pass/fail checks; no host, account, response body, or diagnostic values.\n");
    exit(0);
}

$username = null;
$confirm = false;
foreach (array_slice($argv, 1) as $argument) {
    if ($argument === '--confirm-live-reads') {
        $confirm = true;
    } elseif (str_starts_with($argument, '--username=')) {
        $username = substr($argument, strlen('--username='));
    } else {
        fwrite(STDERR, "Unsupported argument. See --help.\n");
        exit(2);
    }
}
if (!$confirm || !is_string($username) || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1) {
    fwrite(STDERR, "Choose one valid account and explicitly confirm the six live read-only probes. See --help.\n");
    exit(2);
}

if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() !== 0
    || !is_file(ORM_CPanel_ROOT . '/bin/whmapi1')
    || !is_file(ORM_INSTALL_ROOT . '/src/Orm/Security/WhmAuditLog.php')
    || !function_exists('curl_init')) {
    fwrite(STDERR, "Live WHM diagnostics smoke requires root, cPanel, installed ORM, and PHP cURL.\n");
    exit(2);
}

require_once ORM_INSTALL_ROOT . '/src/Orm/Security/WhmAuditLog.php';

/** @return array{code:int,body:string,location:?string} */
$request = static function (string $host, string $path, string $cookieFile, ?array $form = null): array {
    $location = null;
    $handle = curl_init('https://' . $host . ':2087' . $path);
    if ($handle === false) {
        throw new RuntimeException('WHM request initialization failed');
    }
    $headers = ['Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'];
    $options = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => $headers,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT => 20,
        CURLOPT_ENCODING => '',
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_SSL_VERIFYPEER => false,
        CURLOPT_SSL_VERIFYHOST => 0,
        CURLOPT_RESOLVE => [$host . ':2087:127.0.0.1'],
        CURLOPT_COOKIEFILE => $cookieFile,
        CURLOPT_COOKIEJAR => $cookieFile,
        CURLOPT_HEADERFUNCTION => static function ($curl, string $line) use (&$location): int {
            if (stripos($line, 'Location:') === 0) {
                $location = trim(substr($line, strlen('Location:')));
            }
            return strlen($line);
        },
    ];
    if ($form !== null) {
        $options[CURLOPT_POST] = true;
        $options[CURLOPT_POSTFIELDS] = http_build_query($form, '', '&', PHP_QUERY_RFC3986);
        $options[CURLOPT_HTTPHEADER] = [
            ...$headers,
            'Content-Type: application/x-www-form-urlencoded',
            'Origin: https://' . $host . ':2087',
        ];
        $options[CURLOPT_REFERER] = 'https://' . $host . ':2087' . $path;
    }
    curl_setopt_array($handle, $options);
    $body = curl_exec($handle);
    $code = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
    $error = curl_error($handle);
    curl_close($handle);
    if (!is_string($body)) {
        throw new RuntimeException($error !== '' ? 'WHM request failed' : 'WHM returned no response');
    }
    return ['code' => $code, 'body' => $body, 'location' => $location];
};

/** @return array{code:int,body:string} */
$followSameSessionRedirects = static function (string $host, string $path, string $cookieFile) use ($request): array {
    $prefix = preg_match('~\A(/cpsess[0-9]{10})(?:/|\z)~', $path, $match) === 1 ? $match[1] : null;
    if ($prefix === null) {
        throw new RuntimeException('WHM SSO did not return a valid session path');
    }
    for ($redirect = 0; $redirect <= 4; ++$redirect) {
        $response = $request($host, $path, $cookieFile);
        if (!in_array($response['code'], [301, 302, 303, 307, 308], true)) {
            return ['code' => $response['code'], 'body' => $response['body']];
        }
        if (!is_string($response['location']) || $response['location'] === '') {
            throw new RuntimeException('WHM returned an empty redirect');
        }
        $parts = parse_url($response['location']);
        if (!is_array($parts)
            || (isset($parts['host']) && (strtolower($parts['host']) !== strtolower($host)
                || ($parts['scheme'] ?? null) !== 'https' || ($parts['port'] ?? 2087) !== 2087))) {
            throw new RuntimeException('WHM attempted a redirect outside its SSO origin');
        }
        $path = (string) ($parts['path'] ?? '/');
        if (!str_starts_with($path, $prefix . '/') && $path !== $prefix) {
            throw new RuntimeException('WHM attempted a redirect outside the authenticated session');
        }
        $decodedPath = rawurldecode($path);
        if (str_contains($decodedPath, '\\')
            || array_intersect(['.', '..'], explode('/', $decodedPath)) !== []) {
            throw new RuntimeException('WHM returned an unsafe session redirect path');
        }
        if (isset($parts['query'])) {
            $path .= '?' . $parts['query'];
        }
    }
    throw new RuntimeException('WHM SSO exceeded the redirect limit');
};

/** @return int|null */
$auditCount = static function (string $account, string $action, string $result, int $from, int $to): ?int {
    $audit = (new \Orm\Security\WhmAuditLog())->read($from, $to, [
        'account' => $account,
        'action' => $action,
        'result' => $result,
    ]);
    return is_array($audit) && ($audit['success'] ?? null) === true
        ? (int) ($audit['record_count'] ?? -1) : null;
};

$classes = [
    'ping' => ['label' => 'PING', 'fields' => ['Response' => 'ping']],
    'info_server' => ['label' => 'INFO server', 'fields' => ['Server version' => 'version', 'Uptime (seconds)' => 'integer']],
    'info_memory' => ['label' => 'INFO memory', 'fields' => ['Memory used (bytes)' => 'integer', 'Memory peak (bytes)' => 'integer', 'Configured memory limit (bytes)' => 'integer']],
    'info_clients' => ['label' => 'INFO clients', 'fields' => ['Connected clients' => 'integer', 'Blocked clients' => 'integer', 'Client limit' => 'integer']],
    'info_stats' => ['label' => 'INFO stats', 'fields' => ['Commands per second' => 'integer', 'Keyspace hits' => 'integer', 'Keyspace misses' => 'integer', 'Expired keys' => 'integer', 'Evicted keys' => 'integer']],
    'info_commandstats' => ['label' => 'INFO commandstats', 'fields' => [], 'marker' => '<th scope="col">Command</th>'],
    'slowlog' => ['label' => 'SLOWLOG GET', 'fields' => [], 'marker' => '<th scope="col">Logged at (UTC)</th>'],
    'dbsize' => ['label' => 'DBSIZE', 'fields' => ['Keys in database 0' => 'integer']],
];
$boundedValuePresent = static function (string $body, string $label, string $kind): bool {
    $pattern = '/<tr><th scope="row">' . preg_quote($label, '/') . '<\/th>\s*<td>([^<]{1,64})<\/td><\/tr>/s';
    if (preg_match($pattern, $body, $match) !== 1) {
        return false;
    }
    $value = $match[1];
    if ($kind === 'ping') {
        return $value === 'PONG';
    }
    if ($kind === 'version') {
        return preg_match('/\A[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?:[-+][A-Za-z0-9.-]{1,24})?\z/', $value) === 1;
    }
    if (preg_match('/\A(?:0|[1-9][0-9]{0,2}(?:,[0-9]{3})*)\z/', $value) !== 1) {
        return false;
    }
    $integer = filter_var(str_replace(',', '', $value), FILTER_VALIDATE_INT);
    return is_int($integer) && $integer <= 9_000_000_000_000_000;
};
$result = ['sso' => false, 'root_form' => false, 'throttle' => false, 'unsupported_rejected' => false];
foreach (array_keys($classes) as $commandClass) {
    $result[$commandClass] = false;
    $result[$commandClass . '_audit'] = false;
}

$temporaryDirectory = sys_get_temp_dir() . '/orm-whm-diagnostics-' . bin2hex(random_bytes(8));
if (!mkdir($temporaryDirectory, 0700) || !chmod($temporaryDirectory, 0700)) {
    fwrite(STDERR, "Could not create a private temporary directory.\n");
    exit(2);
}
$cookieFile = $temporaryDirectory . '/cookies';
if (file_put_contents($cookieFile, '') === false || !chmod($cookieFile, 0600)) {
    @unlink($cookieFile);
    @rmdir($temporaryDirectory);
    fwrite(STDERR, "Could not create a private SSO cookie file.\n");
    exit(2);
}

try {
    $process = proc_open([
        ORM_CPanel_ROOT . '/bin/whmapi1', '--output=json', 'create_user_session',
        'user=root', 'service=whostmgrd',
    ], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException('Could not request a WHM SSO session');
    }
    fclose($pipes[0]);
    stream_set_timeout($pipes[1], 15);
    stream_set_timeout($pipes[2], 15);
    $apiOutput = stream_get_contents($pipes[1]);
    stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $processStatus = proc_close($process);
    $session = is_string($apiOutput) ? json_decode($apiOutput, true) : null;
    $ssoUrl = is_array($session) ? ($session['data']['url'] ?? null) : null;
    $sso = is_string($ssoUrl) ? parse_url($ssoUrl) : false;
    if ($processStatus !== 0 || !is_array($session) || ($session['metadata']['result'] ?? null) !== 1
        || !is_array($sso) || ($sso['scheme'] ?? null) !== 'https'
        || !is_string($sso['host'] ?? null) || preg_match('/\A[a-zA-Z0-9.-]{1,253}\z/', $sso['host']) !== 1
        || ($sso['port'] ?? 2087) !== 2087 || isset($sso['user']) || isset($sso['pass']) || isset($sso['fragment'])
        || !is_string($sso['path'] ?? null) || preg_match('~\A/cpsess[0-9]{10}/login/?\z~', $sso['path']) !== 1
        || !is_string($sso['query'] ?? null)) {
        throw new RuntimeException('cPanel did not provide a valid WHM SSO session');
    }
    $host = $sso['host'];
    $login = $followSameSessionRedirects($host, $sso['path'] . '?' . $sso['query'], $cookieFile);
    $result['sso'] = $login['code'] >= 200 && $login['code'] < 400;
    $sessionPrefix = preg_match('~\A(/cpsess[0-9]{10})~', $sso['path'], $match) === 1 ? $match[1] : null;
    if (!$result['sso'] || $sessionPrefix === null) {
        throw new RuntimeException('cPanel SSO authentication failed');
    }
    $pagePath = $sessionPrefix . '/cgi/addon_open_redis_manager.php';
    $page = $followSameSessionRedirects($host, $pagePath, $cookieFile);
    $result['root_form'] = $page['code'] === 200
        && str_contains($page['body'], 'name="command_class"')
        && str_contains($page['body'], 'Run read-only probe');
    if (!$result['root_form']) {
        throw new RuntimeException('Authenticated WHM page did not render root diagnostic controls');
    }

    foreach ($classes as $commandClass => $definition) {
        // The broker limits each account's diagnostics to one request per five seconds.
        usleep(5_100_000);
        $startedAt = time();
        $before = $auditCount($username, 'diagnostics.' . $commandClass, 'success', max(0, $startedAt - 2), $startedAt + 1);
        if ($before === null) {
            throw new RuntimeException('Could not establish the diagnostic audit baseline');
        }
        $response = $request($host, $pagePath, $cookieFile, [
            'orm_action' => 'fleet.diagnostics',
            'username' => $username,
            'command_class' => $commandClass,
        ]);
        $body = $response['body'];
        $heading = '<h3>Read-only ' . $definition['label'] . ' result for <code>' . $username . '</code></h3>';
        $fieldsPresent = true;
        if (isset($definition['marker'])) {
            $fieldsPresent = str_contains($body, $definition['marker']);
            if ($commandClass === 'info_commandstats') {
                $fieldsPresent = $fieldsPresent && str_contains($body, 'Total CPU time (µs)');
            }
        }
        foreach ($definition['fields'] as $field => $kind) {
            $fieldsPresent = $fieldsPresent && $boundedValuePresent($body, $field, $kind);
        }
        $result[$commandClass] = $response['code'] === 200 && str_contains($body, $heading)
            && $fieldsPresent && str_contains($body, 'probe completed');
        $after = $auditCount($username, 'diagnostics.' . $commandClass, 'success', max(0, $startedAt - 2), time() + 1);
        $result[$commandClass . '_audit'] = is_int($after) && $after > $before;
        if (!$result[$commandClass] || !$result[$commandClass . '_audit']) {
            throw new RuntimeException('A fixed diagnostic class did not render its bounded result and audit record');
        }

        $rateLimitStartedAt = time();
        $beforeRateLimit = $auditCount($username, 'diagnostics.' . $commandClass, 'rate_limited',
            max(0, $rateLimitStartedAt - 2), $rateLimitStartedAt + 1);
        if ($beforeRateLimit === null) {
            throw new RuntimeException('Could not establish the diagnostic rate-limit audit baseline');
        }
        $repeat = $request($host, $pagePath, $cookieFile, [
            'orm_action' => 'fleet.diagnostics',
            'username' => $username,
            'command_class' => $commandClass,
        ]);
        $repeatRateLimited = $repeat['code'] === 200
            && str_contains($repeat['body'], 'Wait a few seconds before requesting diagnostics for this account again.')
            && !str_contains($repeat['body'], '<h3>Read-only ' . $definition['label'] . ' result');
        $afterRateLimit = $auditCount($username, 'diagnostics.' . $commandClass, 'rate_limited',
            max(0, $rateLimitStartedAt - 2), time() + 1);
        if (!$repeatRateLimited || !is_int($afterRateLimit) || $afterRateLimit <= $beforeRateLimit) {
            throw new RuntimeException('The repeated probe was not rate-limited and audited');
        }
        $result['throttle'] = true;
    }

    usleep(1_100_000);
    $unsupported = $request($host, $pagePath, $cookieFile, [
        'orm_action' => 'fleet.diagnostics',
        'username' => $username,
        'command_class' => 'flushall',
    ]);
    $result['unsupported_rejected'] = $unsupported['code'] === 200
        && str_contains($unsupported['body'], 'diagnostic request could not be verified')
        && !str_contains($unsupported['body'], 'Read-only FLUSHALL result')
        && !str_contains($unsupported['body'], 'flushall');
    if (!$result['unsupported_rejected']) {
        throw new RuntimeException('Unsupported command class was not rejected without reflection');
    }
} catch (Throwable) {
    fwrite(STDERR, "Live WHM diagnostics form smoke failed; sensitive response details were withheld.\n");
    $exitCode = 1;
} finally {
    @unlink($cookieFile);
    @rmdir($temporaryDirectory);
}

$labels = ['sso' => 'SSO', 'root_form' => 'root_form', 'throttle' => 'throttle'];
foreach ($classes as $commandClass => $definition) {
    $labels[$commandClass] = $definition['label'];
    $labels[$commandClass . '_audit'] = $definition['label'] . '_audit';
}
$labels['unsupported_rejected'] = 'unsupported_rejected';
$failed = [];
foreach ($labels as $key => $label) {
    if (($result[$key] ?? false) !== true) {
        $failed[] = $label;
    }
}
if ($failed !== []) {
    fwrite(STDOUT, 'Checks: ' . implode(' ', array_map(static fn (string $label): string => $label . '=fail', $failed)) . "\n");
    exit($exitCode ?? 1);
}
fwrite(STDOUT, "Live WHM diagnostics passed: root form; eight fixed read-only probes rendered with per-class audit events; unsupported class rejected.\n");
