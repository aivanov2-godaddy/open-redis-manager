<?php
declare(strict_types=1);

/**
 * Exercise the authenticated WHM security-report POST through cPanel SSO.
 * This intentionally consumes the report throttle and writes one ORM audit event.
 */

const ORM_CPanel_ROOT = '/usr/local/cpanel';
const ORM_INSTALL_ROOT = '/usr/local/cpanel/3rdparty/orm';

if (in_array('--help', $argv, true)) {
    fwrite(STDOUT, "Usage: php tests/whm-live-security-report-form.php --confirm-report-write\n"
        . "Requires root on a disposable cPanel & WHM host. Generates one report, consumes the one-minute throttle,\n"
        . "and writes a metadata-only audit event. Output contains pass/fail only.\n");
    exit(0);
}

if (!in_array('--confirm-report-write', $argv, true)) {
    fwrite(STDERR, "Refusing to submit a WHM report without --confirm-report-write. See --help.\n");
    exit(2);
}

if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() !== 0
    || !is_file(ORM_CPanel_ROOT . '/bin/whmapi1') || !is_file(ORM_INSTALL_ROOT . '/src/Orm/Security/WhmAuditLog.php')
    || !function_exists('curl_init')) {
    fwrite(STDERR, "Live WHM report-form smoke requires root, cPanel, installed ORM, and PHP cURL.\n");
    exit(2);
}

require_once ORM_INSTALL_ROOT . '/src/Orm/Security/WhmAuditLog.php';

/** @return array{code:int,body:string,location:?string,content_type:?string} */
$request = static function (string $host, string $path, string $cookieFile, ?array $form = null,
    ?string $referer = null): array {
    $location = null;
    $handle = curl_init('https://' . $host . ':2087' . $path);
    if ($handle === false) {
        throw new RuntimeException('curl initialization failed');
    }
    $options = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => ['Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'],
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
            'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Content-Type: application/x-www-form-urlencoded',
            'Origin: https://' . $host . ':2087',
        ];
        if (is_string($referer)) {
            $options[CURLOPT_REFERER] = $referer;
        }
    }
    curl_setopt_array($handle, $options);
    $body = curl_exec($handle);
    $code = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
    $contentType = curl_getinfo($handle, CURLINFO_CONTENT_TYPE);
    $error = curl_error($handle);
    curl_close($handle);
    if (!is_string($body)) {
        throw new RuntimeException($error !== '' ? 'WHM request failed' : 'WHM returned no response');
    }
    return ['code' => $code, 'body' => $body, 'location' => $location,
        'content_type' => is_string($contentType) ? $contentType : null];
};

/** @return array{code:int,body:string} */
$followSameSessionRedirects = static function (string $host, string $path, string $cookieFile) use ($request): array {
    $prefix = preg_match('~\A(/cpsess[0-9]{10})(?:/|\z)~', $path, $match) === 1 ? $match[1] : null;
    if ($prefix === null) {
        throw new RuntimeException('cPanel SSO did not return a valid session path');
    }
    for ($redirect = 0; $redirect <= 4; ++$redirect) {
        $response = $request($host, $path, $cookieFile);
        if (!in_array($response['code'], [301, 302, 303, 307, 308], true)) {
            return ['code' => $response['code'], 'body' => $response['body']];
        }
        $location = $response['location'];
        if (!is_string($location) || $location === '') {
            throw new RuntimeException('WHM returned an empty redirect');
        }
        $parts = parse_url($location);
        if (!is_array($parts)) {
            throw new RuntimeException('WHM returned an invalid redirect');
        }
        if (isset($parts['host']) && (strtolower($parts['host']) !== strtolower($host)
            || ($parts['scheme'] ?? null) !== 'https' || ($parts['port'] ?? 2087) !== 2087)) {
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

$temporaryDirectory = sys_get_temp_dir() . '/orm-whm-report-form-' . bin2hex(random_bytes(8));
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

$result = ['sso' => false, 'root' => false, 'form' => false, 'summary' => false,
    'rendered' => false, 'audit' => false];
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
        || !is_string($sso['host'] ?? null)
        || preg_match('/\A[a-zA-Z0-9.-]{1,253}\z/', $sso['host']) !== 1
        || ($sso['port'] ?? 2087) !== 2087
        || isset($sso['user']) || isset($sso['pass']) || isset($sso['fragment'])
        || !is_string($sso['path'] ?? null)
        || preg_match('~\A/cpsess[0-9]{10}/login/?\z~', $sso['path']) !== 1
        || !is_string($sso['query'] ?? null)) {
        throw new RuntimeException('cPanel did not provide a valid WHM SSO session');
    }
    $host = $sso['host'];
    $ssoPath = $sso['path'] . '?' . $sso['query'];
    $login = $followSameSessionRedirects($host, $ssoPath, $cookieFile);
    $result['sso'] = $login['code'] >= 200 && $login['code'] < 400;

    $sessionPrefix = preg_match('~\A(/cpsess[0-9]{10})~', $sso['path'], $match) === 1 ? $match[1] : null;
    if (!$result['sso'] || $sessionPrefix === null) {
        throw new RuntimeException('cPanel SSO authentication failed');
    }
    $reportPath = $sessionPrefix . '/cgi/addon_open_redis_manager.php';
    $page = $followSameSessionRedirects($host, $reportPath, $cookieFile);
    $result['root'] = str_contains($page['body'], 'Configure report-only thresholds');
    $result['form'] = $page['code'] === 200 && $result['root']
        && str_contains($page['body'], 'Security and abuse review')
        && str_contains($page['body'], 'Generate report-only review');
    if (!$result['form']) {
        throw new RuntimeException('Authenticated WHM page did not render the security report form');
    }

    $summary = $request($host, $reportPath, $cookieFile, ['orm_action' => 'fleet.summary'],
        'https://' . $host . ':2087' . $reportPath);
    $result['summary'] = $summary['code'] === 200
        && str_contains($summary['body'], 'Verified fleet summary');

    $beforeAudit = (new \Orm\Security\WhmAuditLog())->read(max(0, time() - 10), time() + 1, [
        'action' => 'security.report', 'result' => 'success',
    ]);
    if (!is_array($beforeAudit) || ($beforeAudit['success'] ?? false) !== true) {
        throw new RuntimeException('Could not establish the pre-report audit baseline');
    }
    $beforeCount = (int) ($beforeAudit['record_count'] ?? 0);
    $reportStartedAt = time();
    $report = $request($host, $reportPath, $cookieFile, ['orm_action' => 'security.report'],
        'https://' . $host . ':2087' . $reportPath);
    $reportBody = $report['body'];
    $result['rendered'] = $report['code'] === 200
        && str_contains($reportBody, 'Security and abuse review')
        && preg_match('/Generated [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/', $reportBody) === 1;
    $audit = (new \Orm\Security\WhmAuditLog())->read(max(0, $reportStartedAt - 2), time() + 1, [
        'action' => 'security.report', 'result' => 'success',
    ]);
    $result['audit'] = is_array($audit) && ($audit['success'] ?? false) === true
        && (int) ($audit['record_count'] ?? 0) > $beforeCount
        && count(array_filter($audit['records'] ?? [], static fn (array $record): bool =>
            is_string($record['timestamp_utc'] ?? null)
            && strtotime($record['timestamp_utc']) >= $reportStartedAt
            && ($record['state'] ?? null) === 'generated')) > 0;
    if (!$result['rendered']) {
        $title = preg_match('/<title[^>]*>(.*?)<\/title>/is', $reportBody, $titleMatch) === 1
            ? strtolower(trim(strip_tags($titleMatch[1]))) : '';
        $titleClass = $title === '' ? 'missing'
            : (str_contains($title, 'open redis manager') ? 'orm'
                : (str_contains($title, 'webhost manager') || preg_match('/\bwhm\b/', $title) === 1 ? 'whm'
                    : (preg_match('/login|sign in/', $title) === 1 ? 'login'
                        : (preg_match('/error|failure/', $title) === 1 ? 'error' : 'other'))));
        $pageClass = str_contains($title, 'open redis manager') ? 'orm'
            : (str_contains($title, 'login') ? 'login' : (str_contains($title, 'home') ? 'home' : 'other'));
        $diagnostics = 'HTTP ' . $report['code']
            . '; redirect=' . ($report['location'] !== null ? 'yes' : 'no')
            . '; page=' . $pageClass
            . '; invalid_token=' . (stripos($reportBody, 'Invalid Security Token') !== false ? 'yes' : 'no')
            . '; csrf_error=' . (stripos($reportBody, 'CSRF') !== false ? 'yes' : 'no')
            . '; session_expired=' . (stripos($reportBody, 'session has expired') !== false ? 'yes' : 'no')
            . '; throttled=' . (stripos($reportBody, 'limited to one request per minute') !== false ? 'yes' : 'no')
            . '; report_heading=' . (str_contains($reportBody, 'Security and abuse review') ? 'yes' : 'no')
            . '; form_still_present=' . (str_contains($reportBody, 'Generate report-only review') ? 'yes' : 'no')
            . '; generated_label=' . (str_contains($reportBody, 'Generated ') ? 'yes' : 'no')
            . '; report_timestamp=' . (preg_match('/Generated [0-9]{4}-/', $reportBody) === 1 ? 'yes' : 'no')
            . '; body_bytes=' . strlen($reportBody)
            . '; summary_rendered=' . ($result['summary'] ? 'yes' : 'no')
            . '; response_type=' . (str_starts_with((string) $report['content_type'], 'text/html') ? 'html'
                : (str_starts_with((string) $report['content_type'], 'application/json') ? 'json' : 'other'))
            . '; title_class=' . $titleClass
            . '; html_document=' . (preg_match('/\A\s*<!doctype html|\A\s*<html\b/i', $reportBody) === 1 ? 'yes' : 'no')
            . '; whm_shell=' . (stripos($reportBody, 'WebHost Manager') !== false ? 'yes' : 'no')
            . '; php_error_marker=' . (preg_match('/fatal error|uncaught (?:error|exception|typeerror)/i', $reportBody) === 1 ? 'yes' : 'no')
            . '; audit_event=' . ($result['audit'] ? 'yes' : 'no');
        throw new RuntimeException('WHM POST did not render a generated report (' . $diagnostics . ')');
    }
    if (!$result['audit']) {
        throw new RuntimeException('WHM report audit event was not verified');
    }
} catch (Throwable $error) {
    fwrite(STDERR, "Live WHM report-form smoke failed: " . $error->getMessage() . "\n");
    $exitCode = 1;
} finally {
    @unlink($cookieFile);
    @rmdir($temporaryDirectory);
}

if (isset($exitCode) && $exitCode !== 0) {
    fwrite(STDOUT, 'Checks: sso=' . ($result['sso'] ? 'pass' : 'fail')
        . ' root=' . ($result['root'] ? 'pass' : 'fail')
        . ' form=' . ($result['form'] ? 'pass' : 'fail')
        . ' summary=' . ($result['summary'] ? 'pass' : 'fail')
        . ' rendered=' . ($result['rendered'] ? 'pass' : 'fail')
        . ' audit=' . ($result['audit'] ? 'pass' : 'fail') . "\n");
    exit($exitCode);
}

fwrite(STDOUT, "Live WHM report form passed: authenticated SSO; form rendered; report POST rendered; audit event verified.\n");
