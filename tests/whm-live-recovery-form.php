<?php
declare(strict_types=1);

/**
 * Submit one explicitly confirmed ORM live-recovery operation through a real cPanel SSO session.
 * The harness pins HTTPS to the local WHM/cPanel listener and never prints session or page data.
 */

const ORM_LIVE_WHMAPI = '/usr/local/cpanel/bin/whmapi1';
const ORM_LIVE_PAGE_LIMIT = 2_097_152;
const ORM_LIVE_TIMEOUT = 20;

if (in_array('--help', $argv, true)) {
    fwrite(STDOUT, "Usage: php tests/whm-live-recovery-form.php --mode=backend-select|provision|stop|scan|repair [--username=ACCOUNT] [--backend=redis|valkey] --confirm-live-operation\n"
        . "Requires root on a disposable cPanel & WHM host. This submits one allowlisted authenticated form.\n"
        . "Scan writes an audit event; repair, provision, stop, and backend selection mutate test state.\n"
        . "The harness prints sanitized status only and never prints the SSO URL, cookies, account, or response body.\n");
    exit(0);
}

$mode = null;
$username = null;
$backend = null;
$confirmed = false;
foreach (array_slice($argv, 1) as $argument) {
    if (str_starts_with($argument, '--mode=')) {
        $mode = substr($argument, strlen('--mode='));
    } elseif (str_starts_with($argument, '--username=')) {
        $username = substr($argument, strlen('--username='));
    } elseif (str_starts_with($argument, '--backend=')) {
        $backend = substr($argument, strlen('--backend='));
    } elseif ($argument === '--confirm-live-operation') {
        $confirmed = true;
    } else {
        fwrite(STDERR, "Unsupported argument. See --help.\n");
        exit(2);
    }
}

$modes = ['backend-select', 'provision', 'stop', 'scan', 'repair'];
$accountModes = ['provision', 'stop', 'scan', 'repair'];
if (!is_string($mode) || !in_array($mode, $modes, true) || !$confirmed
    || (in_array($mode, $accountModes, true)
        && (!is_string($username) || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1))
    || ($mode === 'backend-select' && !in_array($backend, ['redis', 'valkey'], true))
    || ($mode !== 'backend-select' && $backend !== null)) {
    fwrite(STDERR, "Choose one valid live-operation mode, its required arguments, and --confirm-live-operation. See --help.\n");
    exit(2);
}
if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() !== 0
    || !is_file(ORM_LIVE_WHMAPI) || !function_exists('curl_init')) {
    fwrite(STDERR, "Live form smoke requires root, cPanel, and PHP cURL on the cPanel host.\n");
    exit(2);
}

/** @return array{host:string,port:int,prefix:string,loginPath:string} */
function createSession(string $user, string $service, int $port): array
{
    $process = proc_open([
        ORM_LIVE_WHMAPI, '--output=json', 'create_user_session', 'user=' . $user, 'service=' . $service,
    ], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException('SSO session creation failed');
    }
    fclose($pipes[0]);
    stream_set_timeout($pipes[1], 15);
    stream_set_timeout($pipes[2], 15);
    $stdout = stream_get_contents($pipes[1]);
    stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $status = proc_close($process);
    $payload = is_string($stdout) ? json_decode($stdout, true) : null;
    $url = is_array($payload) ? ($payload['data']['url'] ?? null) : null;
    $parts = is_string($url) ? parse_url($url) : false;
    if ($status !== 0 || !is_array($payload) || ($payload['metadata']['result'] ?? null) !== 1
        || !is_array($parts) || ($parts['scheme'] ?? null) !== 'https'
        || !is_string($parts['host'] ?? null)
        || preg_match('/\A[a-zA-Z0-9.-]{1,253}\z/', $parts['host']) !== 1
        || ($parts['port'] ?? $port) !== $port || isset($parts['user']) || isset($parts['pass'])
        || isset($parts['fragment']) || !is_string($parts['path'] ?? null)
        || preg_match('~\A(/cpsess[0-9]{10})/login/?\z~', $parts['path'], $match) !== 1
        || !is_string($parts['query'] ?? null) || $parts['query'] === '') {
        throw new RuntimeException('cPanel did not provide a valid SSO session');
    }
    return ['host' => $parts['host'], 'port' => $port, 'prefix' => $match[1],
        'loginPath' => $parts['path'] . '?' . $parts['query']];
}

/** @return array{status:int,body:string,location:?string} */
function requestPage(string $host, int $port, string $path, string $cookieFile, ?array $form = null): array
{
    $body = '';
    $location = null;
    $handle = curl_init('https://' . $host . ':' . $port . $path);
    if ($handle === false) {
        throw new RuntimeException('cURL initialization failed');
    }
    $headers = ['Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'];
    $options = [
        CURLOPT_RETURNTRANSFER => false,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT => ORM_LIVE_TIMEOUT,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_SSL_VERIFYPEER => false,
        CURLOPT_SSL_VERIFYHOST => 0,
        CURLOPT_RESOLVE => [$host . ':' . $port . ':127.0.0.1'],
        CURLOPT_COOKIEFILE => $cookieFile,
        CURLOPT_COOKIEJAR => $cookieFile,
        CURLOPT_HTTPHEADER => $headers,
        CURLOPT_HEADERFUNCTION => static function ($curl, string $line) use (&$location): int {
            if (stripos($line, 'Location:') === 0) {
                $location = trim(substr($line, strlen('Location:')));
            }
            return strlen($line);
        },
        CURLOPT_WRITEFUNCTION => static function ($curl, string $chunk) use (&$body): int {
            if (strlen($body) + strlen($chunk) > ORM_LIVE_PAGE_LIMIT) {
                return 0;
            }
            $body .= $chunk;
            return strlen($chunk);
        },
    ];
    if ($form !== null) {
        $options[CURLOPT_POST] = true;
        $options[CURLOPT_POSTFIELDS] = http_build_query($form, '', '&', PHP_QUERY_RFC3986);
        $options[CURLOPT_HTTPHEADER] = [...$headers, 'Content-Type: application/x-www-form-urlencoded',
            'Origin: https://' . $host . ':' . $port];
        $options[CURLOPT_REFERER] = 'https://' . $host . ':' . $port . $path;
    }
    curl_setopt_array($handle, $options);
    $ok = curl_exec($handle);
    $status = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
    curl_close($handle);
    if ($ok === false) {
        throw new RuntimeException('WHM request failed or exceeded the bounded response size');
    }
    return ['status' => $status, 'body' => $body, 'location' => $location];
}

/** @return array{status:int,body:string} */
function followSameSession(string $host, int $port, string $path, string $prefix, string $cookieFile,
    ?array $form = null): array
{
    for ($redirect = 0; $redirect <= 4; ++$redirect) {
        $response = requestPage($host, $port, $path, $cookieFile, $form);
        $form = null;
        if (!in_array($response['status'], [301, 302, 303, 307, 308], true)) {
            return ['status' => $response['status'], 'body' => $response['body']];
        }
        if (!is_string($response['location']) || $response['location'] === '') {
            throw new RuntimeException('WHM returned an invalid redirect');
        }
        $parts = parse_url($response['location']);
        if (!is_array($parts)
            || (isset($parts['host']) && (strtolower($parts['host']) !== strtolower($host)
                || ($parts['scheme'] ?? null) !== 'https' || ($parts['port'] ?? $port) !== $port))) {
            throw new RuntimeException('WHM attempted a redirect outside the authenticated origin');
        }
        $path = (string) ($parts['path'] ?? '/');
        if (!str_starts_with($path, $prefix . '/') && $path !== $prefix) {
            throw new RuntimeException('WHM attempted a redirect outside the authenticated session');
        }
        $decoded = rawurldecode($path);
        if (str_contains($decoded, '\\') || array_intersect(['.', '..'], explode('/', $decoded)) !== []) {
            throw new RuntimeException('WHM returned an unsafe session redirect');
        }
        if (isset($parts['query'])) {
            $path .= '?' . $parts['query'];
        }
    }
    throw new RuntimeException('WHM SSO exceeded its redirect limit');
}

$whmMode = in_array($mode, ['backend-select', 'scan', 'repair'], true);
$port = $whmMode ? 2087 : 2083;
$service = $whmMode ? 'whostmgrd' : 'cpaneld';
$sessionUser = $whmMode ? 'root' : (string) $username;
$pagePath = $whmMode ? '/cgi/addon_open_redis_manager.php' : '/frontend/jupiter/orm/index.live.php';
$form = match ($mode) {
    'backend-select' => ['orm_action' => 'backend.select', 'backend' => $backend],
    'provision' => ['orm_action' => 'provision', 'orm_preset' => 'generic'],
    'stop' => ['orm_action' => 'stop'],
    'scan' => ['orm_action' => 'fleet.recovery.scan', 'username' => $username],
    'repair' => ['orm_action' => 'fleet.recovery.repair', 'username' => $username, 'repair' => 'ownership_fix'],
};
$expectedText = match ($mode) {
    'backend-select' => 'The default backend for new ORM instances has been updated.',
    'provision' => 'Action accepted.',
    'stop' => 'Action accepted.',
    'scan' => 'incorrect ownership or permissions',
    'repair' => 'Data ownership and private modes restored and verified',
};
$tempDirectory = sys_get_temp_dir() . '/orm-live-recovery-' . bin2hex(random_bytes(8));
if (!mkdir($tempDirectory, 0700) || !chmod($tempDirectory, 0700)) {
    fwrite(STDERR, "Could not create private SSO state.\n");
    exit(2);
}
$cookieFile = $tempDirectory . '/cookies';
$phase = 'cookie-setup';
$failureCode = 'request-failed';
try {
    if (file_put_contents($cookieFile, '') === false || !chmod($cookieFile, 0600)) {
        throw new RuntimeException('Could not create private SSO cookie file');
    }
    $phase = 'sso-session';
    $session = createSession($sessionUser, $service, $port);
    $phase = 'sso-login';
    $landing = followSameSession($session['host'], $port, $session['loginPath'], $session['prefix'], $cookieFile);
    if ($landing['status'] < 200 || $landing['status'] >= 400) {
        throw new RuntimeException('SSO did not establish an authenticated session');
    }
    $phase = 'authenticated-page';
    $page = followSameSession($session['host'], $port, $session['prefix'] . $pagePath,
        $session['prefix'], $cookieFile);
    if ($page['status'] !== 200 || !str_contains($page['body'], 'Open Redis Manager')) {
        throw new RuntimeException('Authenticated ORM page was unavailable');
    }
    if (!$whmMode && preg_match(
        '/<p\b[^>]*>\s*Verified cPanel account:\s*<code\b[^>]*>([^<]*)<\/code>/i',
        $page['body'], $identity) !== 1
        || (!$whmMode && html_entity_decode($identity[1], ENT_QUOTES | ENT_HTML5) !== $username)) {
        throw new RuntimeException('Authenticated cPanel account identity did not match the requested account');
    }
    $phase = 'form-submit';
    // The authenticated page performs several bounded broker reads; let their shared rate bucket reset.
    usleep(2_000_000);
    $result = followSameSession($session['host'], $port, $session['prefix'] . $pagePath,
        $session['prefix'], $cookieFile, $form);
    $visible = preg_replace('/\s+/', ' ', html_entity_decode(strip_tags($result['body']), ENT_QUOTES | ENT_HTML5));
    $expectedResult = is_string($visible) && str_contains($visible, $expectedText);
    if ($mode === 'stop') {
        $expectedResult = is_string($visible) && str_contains($visible, 'Stopped');
    } elseif ($mode === 'scan') {
        $expectedResult = $expectedResult && str_contains((string) $visible, 'Repair data tree ownership');
        $expectedResult = $expectedResult
            && str_contains((string) $visible, 'recorded in the system authentication log');
    } elseif ($mode === 'repair') {
        $expectedResult = $expectedResult && str_contains((string) $visible, 'Current state: stopped.')
            && str_contains((string) $visible, 'service was not started')
            && str_contains((string) $visible, 'repair was recorded in the system authentication log');
    }
    if ($result['status'] !== 200 || !$expectedResult) {
        $failureCode = 'response-marker-missing';
        $knownErrors = [
            'backend_policy_required' => 'Your hosting provider must select an installed backend',
            'backend_unavailable' => 'The selected cache backend is not available',
            'provider_policy_denied' => 'Your hosting package does not allow this cache setup',
            'provider_policy_unavailable' => 'The hosting provider policy could not be verified',
            'instance_exists' => 'An instance record already exists',
            'storage_unavailable' => 'private storage is unavailable',
            'service_failed' => 'service could not complete that action',
            'operation_in_progress' => 'Another cache operation is running',
            'rate_limited' => 'Please wait a moment before trying another action',
        ];
        if (is_string($visible)) {
            foreach ($knownErrors as $code => $message) {
                if (str_contains($visible, $message)) {
                    $failureCode = $code;
                    break;
                }
            }
        }
        throw new RuntimeException('The authenticated form did not report the expected result');
    }
    fwrite(STDOUT, 'mode=' . $mode . ' http=' . $result['status'] . " result=verified\n");
} catch (Throwable $error) {
    fwrite(STDERR, 'Live recovery form failed at ' . $phase . ' (' . $failureCode . ', ' . get_class($error) . ").\n");
    $status = 1;
} finally {
    if (is_file($cookieFile) && !is_link($cookieFile)) {
        unlink($cookieFile);
    }
    rmdir($tempDirectory);
}
if (isset($status)) {
    exit($status);
}
