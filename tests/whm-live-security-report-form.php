<?php
declare(strict_types=1);

/**
 * Exercise the authenticated WHM security-report POST through cPanel SSO.
 * This intentionally consumes the report throttle and writes one ORM audit event.
 */

const ORM_CPanel_ROOT = '/usr/local/cpanel';
const ORM_INSTALL_ROOT = '/usr/local/cpanel/3rdparty/orm';

if (in_array('--help', $argv, true)) {
    fwrite(STDOUT, "Usage: php tests/whm-live-security-report-form.php (--fleet-summary-only | --fleet-summary-fast | --confirm-report-write | --confirm-report-fast | --confirm-policy-roundtrip)\n"
        . "Requires root on a disposable cPanel & WHM host. The fleet-summary modes submit only a read-only POST.\n"
        . "The fast modes skip waits to exercise rapid submits while fleet operations may be rate-limited.\n"
        . "The policy-roundtrip mode changes one report-only threshold temporarily, then restores its original value.\n"
        . "It writes metadata-only threshold audit events and does not enforce policy or change Redis services.\n"
        . "The report-write mode generates one report, consumes its one-minute throttle, and writes a metadata-only\n"
        . "audit event. Output contains sanitized status and response diagnostics only.\n");
    exit(0);
}

$fleetSummaryOnly = in_array('--fleet-summary-only', $argv, true);
$fleetSummaryFast = in_array('--fleet-summary-fast', $argv, true);
$confirmReportWrite = in_array('--confirm-report-write', $argv, true);
$confirmReportFast = in_array('--confirm-report-fast', $argv, true);
$confirmPolicyRoundtrip = in_array('--confirm-policy-roundtrip', $argv, true);
$selectedModes = (int) $fleetSummaryOnly + (int) $fleetSummaryFast
    + (int) $confirmReportWrite + (int) $confirmReportFast + (int) $confirmPolicyRoundtrip;
if ($selectedModes !== 1) {
    fwrite(STDERR, "Choose exactly one live smoke mode. See --help.\n");
    exit(2);
}
$fleetSummaryOnly = $fleetSummaryOnly || $fleetSummaryFast;
$confirmReportWrite = $confirmReportWrite || $confirmReportFast;
$fastMode = $fleetSummaryFast || $confirmReportFast;

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

$readThresholds = static function (string $html): ?array {
    $fields = [
        'security_evictions_threshold',
        'security_operations_threshold',
        'security_auth_failures_threshold',
    ];
    $thresholds = [];
    foreach ($fields as $field) {
        $pattern = '/<input\b[^>]*\bname="' . preg_quote($field, '/') . '"[^>]*\bvalue="([0-9]+)"/';
        if (preg_match($pattern, $html, $match) !== 1) {
            return null;
        }
        $value = filter_var($match[1], FILTER_VALIDATE_INT);
        if (!is_int($value) || $value < 0 || $value > 9_000_000_000_000_000) {
            return null;
        }
        $thresholds[$field] = $value;
    }
    return $thresholds;
};
$submitThresholds = static function (string $host, string $path, string $cookieFile, array $thresholds) use ($request, $readThresholds): array {
    $response = $request($host, $path, $cookieFile, [
        'orm_action' => 'security.policy.update',
        ...$thresholds,
    ], 'https://' . $host . ':2087' . $path);
    $successMessage = 'Report-only thresholds saved. No automatic enforcement or service changes were applied.';
    return [
        'ok' => $response['code'] === 200 && str_contains($response['body'], $successMessage),
        'thresholds' => $readThresholds($response['body']),
    ];
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

$result = [
    'sso' => false,
    'root' => false,
    'form' => false,
    'summary' => false,
    'rendered' => false,
    'audit' => false,
    'policy_changed' => false,
    'policy_restored' => false,
];
$policyBaseline = null;
$policyRestoreNeeded = false;
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

    // The page GET immediately above uses the fleet.list broker rate bucket.
    // A real user submits after the page is rendered; don't race that 1/sec limit.
    if (!$fastMode) {
        usleep(1_100_000);
    }
    $summary = $request($host, $reportPath, $cookieFile, ['orm_action' => 'fleet.summary'],
        'https://' . $host . ':2087' . $reportPath);
    $result['summary'] = $summary['code'] === 200
        && str_contains($summary['body'], 'Verified fleet summary');

    if ($fleetSummaryOnly && !$result['summary']) {
        throw new RuntimeException('WHM fleet-summary POST did not render the expected summary markup');
    }
    if ($fleetSummaryFast
        && (!str_contains($summary['body'], 'Security and abuse review')
            || !str_contains($summary['body'], 'Generate report-only review'))) {
        throw new RuntimeException('Rapid fleet-list throttling hid the WHM security report form');
    }

    if (!$fleetSummaryOnly && !$confirmPolicyRoundtrip) {
    $beforeAudit = (new \Orm\Security\WhmAuditLog())->read(max(0, time() - 10), time() + 1, [
        'action' => 'security.report', 'result' => 'success',
    ]);
    if (!is_array($beforeAudit) || ($beforeAudit['success'] ?? false) !== true) {
        throw new RuntimeException('Could not establish the pre-report audit baseline');
    }
    $beforeCount = (int) ($beforeAudit['record_count'] ?? 0);
    $reportStartedAt = time();
    // The fleet-summary POST above consumes a separate 1/sec broker bucket.
    // Let it expire before the report requests fresh summary metrics.
    if (!$fastMode) {
        usleep(1_100_000);
    }
    $report = $request($host, $reportPath, $cookieFile, ['orm_action' => 'security.report'],
        'https://' . $host . ':2087' . $reportPath);
    $reportBody = $report['body'];
    $requireValkeyEvidence = getenv('ORM_LIVE_REQUIRE_VALKEY_EVIDENCE') === '1';
    $valkeyFindingsRendered = !$requireValkeyEvidence || (
        str_contains($reportBody, '<strong>Eviction Rate</strong>')
        && str_contains($reportBody, '<strong>Operation Rate</strong>')
        && str_contains($reportBody, '<strong>Client Authentication Failures</strong>')
    );
    $result['rendered'] = $report['code'] === 200
        && str_contains($reportBody, 'Security and abuse review')
        && preg_match('/Generated [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/', $reportBody) === 1
        && $valkeyFindingsRendered;
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
    }
    if ($confirmPolicyRoundtrip) {
        $policyBaseline = $readThresholds($page['body']);
        if (!is_array($policyBaseline)) {
            throw new RuntimeException('The report threshold values could not be read from the authenticated page');
        }
        $policyTrial = $policyBaseline;
        $currentEvictionsThreshold = $policyBaseline['security_evictions_threshold'];
        $policyTrial['security_evictions_threshold'] = $currentEvictionsThreshold < 9_000_000_000_000_000
            ? $currentEvictionsThreshold + 1
            : $currentEvictionsThreshold - 1;
        $policyRestoreNeeded = true;
        $trial = $submitThresholds($host, $reportPath, $cookieFile, $policyTrial);
        if (!$trial['ok'] || $trial['thresholds'] !== $policyTrial) {
            throw new RuntimeException('The authenticated threshold update was not verified');
        }
        $result['policy_changed'] = true;
        $restored = $submitThresholds($host, $reportPath, $cookieFile, $policyBaseline);
        if (!$restored['ok'] || $restored['thresholds'] !== $policyBaseline) {
            throw new RuntimeException('The original report thresholds were not restored');
        }
        $result['policy_restored'] = true;
        $policyRestoreNeeded = false;
    }
} catch (Throwable $error) {
    if ($confirmPolicyRoundtrip && $policyRestoreNeeded && is_array($policyBaseline)
        && isset($host, $reportPath, $cookieFile)) {
        try {
            $restored = $submitThresholds($host, $reportPath, $cookieFile, $policyBaseline);
            $result['policy_restored'] = $restored['ok'] && $restored['thresholds'] === $policyBaseline;
            $policyRestoreNeeded = !$result['policy_restored'];
        } catch (Throwable) {
            $result['policy_restored'] = false;
        }
    }
    $errorMessage = $error->getMessage();
    if ($confirmPolicyRoundtrip && !$result['policy_restored'] && $policyRestoreNeeded) {
        $errorMessage .= ' The original threshold values could not be verified after the restore attempt; inspect the WHM policy before further use.';
    }
    fwrite(STDERR, "Live WHM report-form smoke failed: " . $errorMessage . "\n");
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
        . ' audit=' . ($result['audit'] ? 'pass' : 'fail')
        . ' policy_changed=' . ($result['policy_changed'] ? 'pass' : 'not-run')
        . ' policy_restored=' . ($result['policy_restored'] ? 'pass' : 'not-run') . "\n");
    exit($exitCode);
}

if ($fleetSummaryOnly) {
    $mode = $fleetSummaryFast ? 'fast ' : '';
    fwrite(STDOUT, "Live WHM {$mode}fleet-summary form passed: authenticated SSO; form rendered; read-only summary POST rendered.\n");
} elseif ($confirmPolicyRoundtrip) {
    fwrite(STDOUT, "Live WHM threshold roundtrip passed: authenticated SSO; temporary advisory threshold update verified; original thresholds restored.\n");
} elseif (getenv('ORM_LIVE_REQUIRE_VALKEY_EVIDENCE') === '1') {
    fwrite(STDOUT, "Live WHM Valkey report form passed: authenticated SSO; eviction, operation, and optional authentication findings rendered; audit event verified.\n");
} else {
    fwrite(STDOUT, "Live WHM report form passed: authenticated SSO; form rendered; report POST rendered; audit event verified.\n");
}
