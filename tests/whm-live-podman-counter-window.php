<?php
declare(strict_types=1);

/**
 * Collect two continuity-verified EA Podman samples for one disposable account
 * and check the installed broker/report path. Requires root on a disposable
 * cPanel host. The sampler reads fixed INFO counters only; it never reads keys.
 */

const ORM_CPanel_ROOT = '/usr/local/cpanel';
const ORM_INSTALL_ROOT = '/usr/local/cpanel/3rdparty/orm';
const ORM_SAMPLER_STATE = '/var/lib/orm-podman';

if (in_array('--help', $argv, true)) {
    fwrite(STDOUT, "Usage: php tests/whm-live-podman-counter-window.php --account=ACCOUNT\n"
        . "Requires root on a disposable cPanel host, one running EA Podman Redis/Valkey cache,\n"
        . "an inactive ORM sampler timer, and no existing /var/lib/orm-podman state.\n"
        . "It takes two samples 65 seconds apart, verifies report findings, then removes only\n"
        . "the state it created. Output contains aggregate status only.\n");
    exit(0);
}

if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() !== 0
    || !is_file(ORM_CPanel_ROOT . '/3rdparty/bin/perl')
    || !is_file(ORM_CPanel_ROOT . '/3rdparty/orm/bin/orm-podman-metrics-collect.pl')) {
    fwrite(STDERR, "Live Podman counter validation requires root, cPanel, and the installed sampler.\n");
    exit(2);
}

$account = null;
foreach ($argv as $argument) {
    if (str_starts_with($argument, '--account=')) {
        $account = substr($argument, strlen('--account='));
    }
}
if (!is_string($account) || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $account) !== 1) {
    fwrite(STDERR, "Provide one valid disposable cPanel account with --account.\n");
    exit(2);
}

foreach ([
    'Cpanel/BrokerClient.php',
    'Security/WhmAuditLog.php',
    'Security/WhmSecurityReportPolicyStore.php',
    'Security/WhmSecurityReport.php',
] as $file) {
    $path = ORM_INSTALL_ROOT . '/src/Orm/' . $file;
    if (!is_file($path) || !is_readable($path)) {
        fwrite(STDERR, "An installed ORM report component is unavailable.\n");
        exit(2);
    }
    require_once $path;
}

$isCommandActive = static function (array $command): bool {
    $process = proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($process)) {
        return true;
    }
    fclose($pipes[0]);
    stream_get_contents($pipes[1]);
    stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    return proc_close($process) === 0;
};
if ($isCommandActive(['systemctl', 'is-enabled', '--quiet', 'orm-podman-metrics.timer'])
    || $isCommandActive(['systemctl', 'is-active', '--quiet', 'orm-podman-metrics.timer'])) {
    fwrite(STDERR, "The scheduled sampler must be disabled for this isolated validation.\n");
    exit(2);
}
clearstatcache(true, ORM_SAMPLER_STATE);
if (@lstat(ORM_SAMPLER_STATE) !== false) {
    fwrite(STDERR, "Existing sampler state was found; refusing to replace it.\n");
    exit(2);
}

$accountRoot = sys_get_temp_dir() . '/orm-podman-counter-' . bin2hex(random_bytes(8));
$accountFile = $accountRoot . '/' . $account;
$perlCode = '$resolver=Orm::Broker::AccountResolver->new();'
    . '$collector=Orm::Broker::PodmanMetricsCollector->new(resolver=>$resolver,'
    . 'account_root=>$ARGV[0],snapshot_path=>"' . ORM_SAMPLER_STATE . '/summary.json",max_accounts=>1);'
    . '$snapshot=$collector->collect_and_write();exit(ref($snapshot) eq "HASH"?0:1);';
$result = [
    'first_sample' => false,
    'measured_window' => false,
    'broker_window' => false,
    'report_findings' => false,
    'engine_smoke' => false,
    'whm_form_smoke' => false,
];
$cleanupComplete = true;
$exitCode = 0;

$runCollector = static function () use ($accountRoot, $perlCode): bool {
    $process = proc_open([
        ORM_CPanel_ROOT . '/3rdparty/bin/perl',
        '-I' . ORM_INSTALL_ROOT . '/lib',
        '-MOrm::Broker::AccountResolver',
        '-MOrm::Broker::PodmanMetricsCollector',
        '-e',
        $perlCode,
        $accountRoot,
    ], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($process)) {
        return false;
    }
    fclose($pipes[0]);
    stream_get_contents($pipes[1]);
    stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    return proc_close($process) === 0;
};
$readSnapshot = static function (): ?array {
    $path = ORM_SAMPLER_STATE . '/summary.json';
    $stat = @lstat($path);
    if (!is_array($stat) || (($stat['mode'] & 0170000) !== 0100000)
        || $stat['uid'] !== 0 || $stat['nlink'] !== 1 || ($stat['mode'] & 0777) !== 0600
        || $stat['size'] > 4096) {
        return null;
    }
    $raw = @file_get_contents($path);
    if (!is_string($raw) || strlen($raw) > 4096) {
        return null;
    }
    try {
        $snapshot = json_decode($raw, true, 12, JSON_THROW_ON_ERROR);
        return is_array($snapshot) ? $snapshot : null;
    } catch (Throwable) {
        return null;
    }
};

try {
    if (!mkdir($accountRoot, 0700) || !chmod($accountRoot, 0700)
        || file_put_contents($accountFile, '') !== 0 || !chmod($accountFile, 0600)
        || !mkdir(ORM_SAMPLER_STATE, 0700) || !chmod(ORM_SAMPLER_STATE, 0700)) {
        throw new RuntimeException('Could not create private validation state');
    }

    if (!$runCollector()) {
        throw new RuntimeException('The first account-scoped sampler invocation failed');
    }
    $first = $readSnapshot();
    if (!is_array($first) || ($first['version'] ?? null) !== 2
        || ($first['scan_complete'] ?? false) !== true || ($first['partial'] ?? true) !== false
        || ($first['reachable_count'] ?? 0) < 1
        || ($first['reachable_count'] ?? null) !== ($first['sampled_count'] ?? null)
        || ($first['counter_window']['status'] ?? null) !== 'unknown'
        || ($first['counter_window']['reason'] ?? null) !== 'first_sample') {
        throw new RuntimeException('The first sample was not a complete initial Podman measurement');
    }
    $result['first_sample'] = true;

    $remaining = 65;
    while ($remaining > 0) {
        $remaining = sleep($remaining);
    }
    if (!$runCollector()) {
        throw new RuntimeException('The second account-scoped sampler invocation failed');
    }
    $second = $readSnapshot();
    $window = is_array($second['counter_window'] ?? null) ? $second['counter_window'] : [];
    if (!is_array($second) || ($second['version'] ?? null) !== 2
        || ($second['scan_complete'] ?? false) !== true || ($second['partial'] ?? true) !== false
        || ($second['reachable_count'] ?? 0) < 1
        || ($window['status'] ?? null) !== 'measured'
        || ($window['process_count'] ?? 0) !== ($second['reachable_count'] ?? null)
        || ($window['window_seconds'] ?? 0) < 60
        || ($window['sampled_at'] ?? null) !== ($second['sampled_at'] ?? null)) {
        throw new RuntimeException('The second sample did not verify process continuity and monotonic counters');
    }
    $result['measured_window'] = true;

    $fleet = (new \Orm\Cpanel\BrokerClient())->requestFleetSummary();
    $podman = is_array($fleet['podman_metrics'] ?? null) ? $fleet['podman_metrics'] : [];
    $brokerWindow = is_array($podman['counter_window'] ?? null) ? $podman['counter_window'] : [];
    if (!is_array($fleet) || ($fleet['success'] ?? false) !== true
        || ($brokerWindow['status'] ?? null) !== 'measured'
        || ($brokerWindow['process_count'] ?? null) !== ($window['process_count'] ?? null)) {
        throw new RuntimeException('The local broker did not expose the anonymous measured window');
    }
    $result['broker_window'] = true;

    $now = time();
    $audit = (new \Orm\Security\WhmAuditLog())->read(max(0, $now - 86400), $now);
    $policy = (new \Orm\Security\WhmSecurityReportPolicyStore())->load();
    $report = \Orm\Security\WhmSecurityReport::build($fleet, $audit, $now, $policy, $policy !== null);
    $findings = is_array($report['findings'] ?? null) ? array_column($report['findings'], null, 'category') : [];
    $authSeverity = $findings['podman_authentication_failures']['severity'] ?? null;
    if (($report['mode'] ?? null) !== 'report-only'
        || !isset($findings['podman_eviction_rate'], $findings['podman_operation_rate'])
        || !in_array($authSeverity, ['info', 'warning', 'unknown'], true)
        || isset($findings['podman_counter_rates_unknown'])
        || isset($report['unmeasured']['ea_podman_counter_rates'])) {
        throw new RuntimeException('The report engine did not build measured Podman counter findings');
    }
    $result['report_findings'] = true;

    if (!putenv('ORM_LIVE_REQUIRE_PODMAN_EVIDENCE=1')) {
        throw new RuntimeException('Could not enable the Podman evidence assertion');
    }
    $runEvidenceCheck = static function (array $arguments, string $expectedOutput): bool {
        $command = ['/usr/bin/timeout', '--signal=KILL', '90s', PHP_BINARY, ...$arguments];
        $process = proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if (!is_resource($process)) {
            return false;
        }
        fclose($pipes[0]);
        $stdout = stream_get_contents($pipes[1], 16_384);
        stream_get_contents($pipes[2], 16_384);
        fclose($pipes[1]);
        fclose($pipes[2]);
        return proc_close($process) === 0 && is_string($stdout) && str_contains($stdout, $expectedOutput);
    };
    // The direct broker query above uses the same one-request-per-second summary bucket.
    usleep(1_100_000);
    if (!$runEvidenceCheck(
        ['/root/whm-live-security-report-engine.php'],
        'EA Podman live report evidence passed:'
    )) {
        throw new RuntimeException('The standalone live WHM report-engine evidence check failed');
    }
    $result['engine_smoke'] = true;

    usleep(1_100_000);
    if (!$runEvidenceCheck(
        ['/root/whm-live-security-report-form.php', '--confirm-report-write'],
        'Live WHM Podman report form passed:'
    )) {
        throw new RuntimeException('The authenticated WHM report-form evidence check failed');
    }
    $result['whm_form_smoke'] = true;
} catch (Throwable $error) {
    fwrite(STDERR, "Live EA Podman counter validation failed: " . $error->getMessage() . "\n");
    $exitCode = 1;
} finally {
    clearstatcache(true, ORM_SAMPLER_STATE);
    $stateStat = @lstat(ORM_SAMPLER_STATE);
    if (is_array($stateStat)) {
        $allowedStateFiles = ['counter-baseline.json', 'counter-baseline.json.lock', 'summary.json'];
        $entries = ($stateStat['mode'] & 0170000) === 0040000
            && $stateStat['uid'] === 0 && ($stateStat['mode'] & 0777) === 0700
            ? @scandir(ORM_SAMPLER_STATE) : false;
        if (!is_array($entries) || array_diff(array_values(array_diff($entries, ['.', '..'])), $allowedStateFiles) !== []) {
            $cleanupComplete = false;
        } else {
            foreach ($allowedStateFiles as $name) {
                $path = ORM_SAMPLER_STATE . '/' . $name;
                clearstatcache(true, $path);
                $stat = @lstat($path);
                if ($stat === false) {
                    continue;
                }
                if (($stat['mode'] & 0170000) !== 0100000 || $stat['uid'] !== 0
                    || $stat['nlink'] !== 1 || ($stat['mode'] & 0777) !== 0600 || !@unlink($path)) {
                    $cleanupComplete = false;
                    break;
                }
            }
            if ($cleanupComplete && !@rmdir(ORM_SAMPLER_STATE)) {
                $cleanupComplete = false;
            }
        }
    }
    clearstatcache(true, $accountRoot);
    $accountDirectoryStat = @lstat($accountRoot);
    if (is_array($accountDirectoryStat)) {
        $accountFileStat = @lstat($accountFile);
        if (($accountDirectoryStat['mode'] & 0170000) !== 0040000 || $accountDirectoryStat['uid'] !== 0
            || ($accountDirectoryStat['mode'] & 0777) !== 0700 || !is_array($accountFileStat)
            || ($accountFileStat['mode'] & 0170000) !== 0100000 || $accountFileStat['uid'] !== 0
            || $accountFileStat['nlink'] !== 1 || ($accountFileStat['mode'] & 0777) !== 0600
            || !@unlink($accountFile) || !@rmdir($accountRoot)) {
            $cleanupComplete = false;
        }
    }
    if (!$cleanupComplete) {
        fwrite(STDERR, "Temporary sampler state could not be fully removed; inspect the test-created validation paths.\n");
        $exitCode = 1;
    }
}

if ($exitCode !== 0) {
    exit($exitCode);
}
printf(
    "EA Podman report integration passed: %d process(es) matched for %d seconds; broker and report engine produced report-only eviction, operation, and optional authentication findings; authenticated WHM rendered all findings and verified the report audit event.\n",
    $window['process_count'],
    $window['window_seconds']
);
