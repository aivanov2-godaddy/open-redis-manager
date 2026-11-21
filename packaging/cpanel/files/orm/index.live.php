<?php
declare(strict_types=1);

require_once '/usr/local/cpanel/php/cpanel.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/AuthenticatedAccountContext.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerIdentityVerifier.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerClient.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/ConnectionDetails.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/ApplicationDiscovery.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/DiagnosticReport.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/HealthGuidance.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/PodmanCacheDiscovery.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/PodmanLifecycleManager.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/SessionRequestGuard.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Backend/BackendDiscovery.php';

$cpanel = new CPANEL();
$account = \Orm\Cpanel\AuthenticatedAccountContext::fromLiveApi($cpanel);
$brokerVerified = $account !== null
    && (new \Orm\Cpanel\BrokerIdentityVerifier())->verifies($account->username());
$instanceClient = new \Orm\Cpanel\BrokerClient();
$podmanActionResult = null;
$podmanActionMessage = null;
$podmanAction = $_POST['orm_podman_action'] ?? null;
if ($brokerVerified && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && is_string($podmanAction) && in_array($podmanAction, ['start', 'stop', 'restart'], true)) {
    $podmanContainer = $_POST['orm_podman_container'] ?? null;
    $podmanActionResult = is_string($podmanContainer)
        ? \Orm\Cpanel\PodmanLifecycleManager::manage($account->username(), $podmanContainer, $podmanAction)
        : ['success' => false, 'reason' => 'invalid'];
    $podmanActionMessage = match ($podmanActionResult['reason'] ?? 'failed') {
        'ok' => 'The cPanel container action completed.',
        'unsupported-shell' => 'This account shell does not support cPanel EA Podman controls. Ask your hosting administrator to enable a normal, non-jailed shell.',
        'timeout' => 'The cPanel container action timed out. Check the container status in cPanel before trying again.',
        default => 'The container action could not be completed. Confirm this is an existing container owned by your cPanel account and check its status in cPanel.',
    };
}
$podmanInventory = $account !== null
    ? \Orm\Cpanel\PodmanCacheDiscovery::currentAccountInventory($account->username())
    : ['status' => 'unavailable', 'caches' => []];
$podmanCaches = $podmanInventory['caches'];
$providerExposureResult = $brokerVerified ? $instanceClient->request('provider.exposure') : null;
$providerBrandingResult = $brokerVerified ? $instanceClient->request('provider.branding') : null;
$providerBranding = is_array($providerBrandingResult) && ($providerBrandingResult['success'] ?? false) === true
    && is_array($providerBrandingResult['branding'] ?? null)
    ? $providerBrandingResult['branding'] : [
        'product_name' => 'Open Redis Manager',
        'logo_png_base64' => '',
        'support_url' => '',
        'preset' => 'orm',
        'primary_color' => '#C92319',
        'secondary_color' => '#A91F18',
        'surface_color' => '#FFFFFF',
        'text_color' => '#172536',
        'footer_visible' => true,
    ];
$exposureLevel = is_array($providerExposureResult) && ($providerExposureResult['success'] ?? false) === true
    && in_array($providerExposureResult['exposure'] ?? null, ['simple', 'developer', 'advanced'], true)
    ? $providerExposureResult['exposure'] : 'simple';
$developerExposure = in_array($exposureLevel, ['developer', 'advanced'], true);
$advancedExposure = $exposureLevel === 'advanced';
$actionResult = null;
$action = $_POST['orm_action'] ?? null;
if ($brokerVerified && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)) {
    $allowedActions = ['provision', 'configure', 'start', 'stop', 'auth.rotate', 'auth.disable', 'backup.create', 'backup.restore'];
    if (is_string($action) && in_array($action, $allowedActions, true)) {
        if ($action === 'provision') {
            $preset = $_POST['orm_preset'] ?? 'generic';
            $actionResult = is_string($preset)
                ? $instanceClient->request('instance.provision', $preset)
                : null;
        } elseif ($action === 'configure') {
            $readInteger = static function (string $key, int $minimum, int $maximum): ?int {
                $raw = $_POST[$key] ?? null;
                if (!is_string($raw) || preg_match('/\A(?:0|[1-9][0-9]{0,2})\z/', $raw) !== 1) {
                    return null;
                }
                $value = filter_var($raw, FILTER_VALIDATE_INT);
                return is_int($value) && $value >= $minimum && $value <= $maximum ? $value : null;
            };
            $memory = $readInteger('orm_memory_mib', 8, 64);
            $clients = $readInteger('orm_maxclients', 10, 100);
            $timeout = $readInteger('orm_timeout', 0, 300);
            $policy = $_POST['orm_maxmemory_policy'] ?? null;
            $actionResult = $memory !== null && $clients !== null && $timeout !== null && is_string($policy)
                ? $instanceClient->request('instance.configure', null, [
                    'memory_mib' => $memory,
                    'maxmemory_policy' => $policy,
                    'maxclients' => $clients,
                    'timeout' => $timeout,
                ])
                : null;
        } elseif ($action === 'backup.create') {
            $actionResult = $instanceClient->request('backup.create');
        } elseif ($action === 'backup.restore') {
            $backupId = $_POST['orm_backup_id'] ?? null;
            $actionResult = is_string($backupId) ? $instanceClient->restoreBackup($backupId) : null;
        } elseif ($action === 'auth.rotate') {
            $actionResult = $instanceClient->rotateAuth();
        } elseif ($action === 'auth.disable') {
            $actionResult = $instanceClient->disableAuth();
        } else {
            $actionResult = $instanceClient->request('instance.' . $action);
        }
    }
}
if (in_array($action, ['auth.rotate', 'auth.disable'], true)) {
    header('Cache-Control: no-store, private');
    header('Pragma: no-cache');
    header('X-Content-Type-Options: nosniff');
}
$instanceStatus = $brokerVerified ? $instanceClient->request('instance.status') : null;
$setupMode = $_GET['orm_setup'] ?? 'choose';
if (!is_string($setupMode) || !in_array($setupMode, ['choose', 'native', 'podman'], true)) {
    $setupMode = 'choose';
}
$showSetupWizard = $brokerVerified && is_array($instanceStatus)
    && ($instanceStatus['success'] ?? false) === true && ($instanceStatus['state'] ?? null) === 'not_configured'
    && ($podmanInventory['status'] ?? null) === 'not-installed';
$podmanSetup = $showSetupWizard && $setupMode === 'podman'
    ? \Orm\Cpanel\PodmanLifecycleManager::inspectSetup($account->username()) : null;
$nativeDiscovery = $showSetupWizard && $setupMode === 'native'
    ? (new \Orm\Backend\BackendDiscovery())->discover() : null;
$canRequestMetrics = $brokerVerified && is_array($instanceStatus) && ($instanceStatus['success'] ?? false) === true
    && ($instanceStatus['state'] ?? null) !== 'not_configured';
$authStatus = $canRequestMetrics ? $instanceClient->authStatus() : null;
$authConfigured = is_array($authStatus) && ($authStatus['success'] ?? false) === true
    && is_bool($authStatus['auth_configured'] ?? null)
    ? $authStatus['auth_configured'] : null;
$rotatedSecret = $action === 'auth.rotate' && is_array($actionResult) && ($actionResult['success'] ?? false) === true
    && is_string($actionResult['secret'] ?? null)
    ? $actionResult['secret'] : null;
$liveMetrics = $canRequestMetrics
    ? $instanceClient->request('instance.metrics')
    : null;
$diagnosticGeneratedAt = time();
$diagnosticReport = $brokerVerified
    ? \Orm\Cpanel\DiagnosticReport::build($instanceStatus, $liveMetrics, $diagnosticGeneratedAt, $authConfigured)
    : null;
$diagnosticJson = $diagnosticReport !== null
    ? json_encode($diagnosticReport, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)
    : null;
$applicationScan = $brokerVerified
    && ($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'GET'
    && ($_GET['orm_app_scan'] ?? null) === 'run'
    ? \Orm\Cpanel\ApplicationDiscovery::fromLiveApi($cpanel, $account->username())
    : null;
if ($applicationScan !== null) {
    header('Cache-Control: no-store, private');
}
if ($brokerVerified && ($_SERVER['REQUEST_METHOD'] ?? null) === 'GET'
    && ($_GET['orm_diagnostics'] ?? null) === 'download') {
    $filenameTimestamp = gmdate('Ymd-His', $diagnosticGeneratedAt);
    header('Content-Type: application/json; charset=utf-8');
    header('Content-Disposition: attachment; filename="orm-diagnostics-' . $filenameTimestamp . '.json"');
    header('Cache-Control: no-store, private');
    header('X-Content-Type-Options: nosniff');
    header('Content-Length: ' . strlen($diagnosticJson));
    echo $diagnosticJson;
    $cpanel->end();
    return;
}
$historyRange = is_string($_GET['orm_metrics_range'] ?? null) && in_array($_GET['orm_metrics_range'], ['24h', '7d'], true)
    ? $_GET['orm_metrics_range']
    : '24h';
$metricsHistory = $canRequestMetrics ? $instanceClient->metricsHistory($historyRange) : null;
$canRequestBackups = $brokerVerified && is_array($instanceStatus) && ($instanceStatus['success'] ?? false) === true
    && ($instanceStatus['state'] ?? null) !== 'not_configured';
$backupList = $canRequestBackups ? $instanceClient->request('backup.list') : null;
$downloadFailure = false;
$requestedBackup = $_GET['orm_backup'] ?? null;
if ($requestedBackup !== null) {
    $backupFound = is_string($requestedBackup)
        && preg_match('/\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/', $requestedBackup) === 1
        && is_array($backupList) && ($backupList['success'] ?? false) === true
        && (bool) array_filter($backupList['backups'], static fn (array $backup): bool => $backup['id'] === $requestedBackup);
    $backupDirectory = $account !== null
        ? '/var/lib/orm-instances/.orm-backups/' . $account->username()
        : '';
    $backupPath = $backupFound ? $backupDirectory . '/' . $requestedBackup : '';
    $backupStat = $backupFound ? @lstat($backupPath) : false;
    $resolvedDirectory = $backupFound ? @realpath($backupDirectory) : false;
    $resolvedBackup = $backupFound ? @realpath($backupPath) : false;
    $backupStream = $backupFound && is_array($backupStat) && (($backupStat['mode'] & 0170000) === 0100000)
        && $backupStat['uid'] === 0 && $backupStat['nlink'] === 1 && ($backupStat['mode'] & 0777) === 0640
        && $backupStat['size'] > 0 && $backupStat['size'] <= 134217728
        && is_string($resolvedDirectory) && is_string($resolvedBackup)
        && $resolvedBackup === $resolvedDirectory . '/' . $requestedBackup
        ? @fopen($backupPath, 'rb')
        : false;
    if (is_resource($backupStream)) {
        $openedStat = fstat($backupStream);
        if (is_array($openedStat) && $openedStat['dev'] === $backupStat['dev']
            && $openedStat['ino'] === $backupStat['ino'] && $openedStat['uid'] === 0
            && $openedStat['nlink'] === 1 && ($openedStat['mode'] & 0777) === 0640
            && $openedStat['size'] === $backupStat['size']) {
            header('Content-Type: application/octet-stream');
            header('Content-Disposition: attachment; filename="' . $requestedBackup . '"');
            header('Content-Length: ' . $openedStat['size']);
            header('X-Content-Type-Options: nosniff');
            fpassthru($backupStream);
            fclose($backupStream);
            $cpanel->end();
            return;
        }
        fclose($backupStream);
    }
    http_response_code(404);
    $downloadFailure = true;
}
$connectionDetails = $brokerVerified
    && $authConfigured !== null
    ? \Orm\Cpanel\ConnectionDetails::forAccount($account->username(), $instanceStatus, $authConfigured)
    : null;
$formatBytes = static function (int $bytes): string {
    $units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    $value = (float) $bytes;
    $unit = 0;
    while ($value >= 1024 && $unit < count($units) - 1) {
        $value /= 1024;
        $unit++;
    }
    return number_format($value, $unit === 0 ? 0 : 1) . ' ' . $units[$unit];
};
$hasLiveMetrics = is_array($liveMetrics) && ($liveMetrics['success'] ?? false) === true;
$healthGuidance = \Orm\Cpanel\HealthGuidance::build($instanceStatus, $liveMetrics);
$hitCount = $hasLiveMetrics ? $liveMetrics['keyspace_hits'] + $liveMetrics['keyspace_misses'] : 0;
$hitRatio = $hasLiveMetrics && $hitCount > 0
    ? number_format(($liveMetrics['keyspace_hits'] / $hitCount) * 100, 1) . '%'
    : 'No lookups yet';
$uptimeDays = $hasLiveMetrics ? intdiv($liveMetrics['uptime_seconds'], 86400) : 0;
$uptimeHours = $hasLiveMetrics ? intdiv($liveMetrics['uptime_seconds'] % 86400, 3600) : 0;
$renderHistoryChart = static function (array $samples, string $field, string $label, string $color, bool $ratio = false) use ($formatBytes): void {
    $values = array_map(static function (array $sample) use ($field, $ratio): int|float {
        if ($ratio) {
            $lookups = $sample['keyspace_hits'] + $sample['keyspace_misses'];
            return $lookups > 0 ? ($sample['keyspace_hits'] / $lookups) * 100 : 0;
        }
        return $sample[$field];
    }, $samples);
    $maximum = max($values ?: [0]);
    $minimum = min($values ?: [0]);
    $span = max(1, $maximum - $minimum);
    $lastIndex = max(1, count($values) - 1);
    $points = [];
    foreach ($values as $index => $value) {
        $x = 8 + ($index / $lastIndex) * 284;
        $y = 8 + (1 - (($value - $minimum) / $span)) * 64;
        $points[] = number_format($x, 1, '.', '') . ',' . number_format($y, 1, '.', '');
    }
    $lastValue = $values === [] ? 0 : (float) end($values);
    $formatted = $ratio ? number_format($lastValue, 1) . '%'
        : ($field === 'memory_used_bytes' ? $formatBytes((int) $lastValue) : number_format($lastValue));
    ?>
    <article class="orm-history-chart" aria-label="<?= htmlspecialchars($label, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> history">
      <h4><?= htmlspecialchars($label, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></h4>
      <strong><?= htmlspecialchars($formatted, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong>
      <svg viewBox="0 0 300 88" role="img" aria-label="<?= htmlspecialchars($label, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> trend, <?= count($samples) ?> hourly samples">
        <path d="M8 80H292M8 44H292M8 8H292" fill="none" stroke="#e2e8f0" stroke-width="1"/>
        <?php if ($points !== []): ?><polyline points="<?= htmlspecialchars(implode(' ', $points), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" fill="none" stroke="<?= htmlspecialchars($color, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/><?php endif; ?>
      </svg>
      <span><?= count($samples) ?> hourly samples</span>
    </article>
    <?php
};
$stateClass = match ($instanceStatus['state'] ?? null) {
    'running' => 'is-running',
    'starting', 'stopping' => 'is-pending',
    'failed' => 'is-failed',
    default => 'is-idle',
};
$errorMessages = [
    'backend_policy_required' => 'Your hosting provider must select an installed backend before you can initialize a cache.',
    'backend_unavailable' => 'The selected cache backend is not available right now. Contact your hosting provider.',
    'provider_policy_denied' => 'Your hosting package does not allow this cache setup or memory setting. Contact your hosting provider if you need a different limit.',
    'provider_policy_unavailable' => 'The hosting provider policy could not be verified, so no change was made. Contact your hosting provider.',
    'instance_exists' => 'An instance record already exists. Refresh this page or contact your hosting provider.',
    'invalid_request' => 'The requested setup or configuration values are not valid.',
    'not_configured' => 'Initialize the cache before starting it.',
    'rate_limited' => 'Please wait a moment before trying another action.',
    'configuration_unavailable' => 'ORM could not read supported current settings, so it made no changes. Stop and start the cache to restore its saved settings, then try again.',
    'configuration_failed' => 'The update failed and ORM attempted to restore the previous live settings. Refresh this page to check them.',
    'configuration_storage_unavailable' => 'The settings were not saved. Refresh this page before trying again.',
    'configuration_uncertain' => 'The settings could not be fully verified. Refresh this page and contact your hosting provider if the problem continues.',
    'auth_generation_failed' => 'ORM could not securely generate a new password. No new credential was returned.',
    'auth_rotation_failed' => 'The AUTH change failed. ORM restored and verified the previous authentication state; no new password was returned. Wait briefly before trying again.',
    'auth_disable_failed' => 'AUTH could not be disabled. ORM restored and verified the previous authenticated state; wait briefly before retrying.',
    'auth_recovery_required' => 'ORM could not verify the previous or new password after a service restart. Stop application writes and contact your hosting provider before retrying.',
    'operation_in_progress' => 'Another cache operation is running. Wait for it to finish before trying again.',
    'service_failed' => 'The cache service could not complete that action. Refresh the page and check its status.',
    'storage_unavailable' => 'The cache could not be initialized because its private storage is unavailable.',
    'backup_failed' => 'The snapshot transfer did not complete. No new backup was kept.',
    'backup_invalid' => 'The generated snapshot did not pass validation and was discarded.',
    'backup_in_progress' => 'A backup is already running for this cache. Wait before starting another.',
    'backup_retention_failed' => 'The new snapshot was saved, but ORM could not remove older backups. Contact your hosting provider.',
    'backup_storage_unavailable' => 'Backup storage is unavailable or failed security checks. Contact your hosting provider.',
    'backup_not_found' => 'That snapshot is no longer available. Refresh the page and choose a listed snapshot.',
    'restore_validation_unavailable' => 'The installed Redis-compatible RDB checker is unavailable. No restore was applied; contact your hosting provider.',
    'restore_failed' => 'The restore did not complete. ORM attempted to keep the cache available and retained a safety snapshot; check the current status before trying again.',
    'restore_rollback_failed' => 'ORM could not verify the automatic restore rollback. Check the cache status and contact your hosting provider before retrying.',
];
try {
    if (!$brokerVerified) {
        http_response_code(503);
    }
    print $cpanel->header($providerBranding['product_name']);
    ?>
    <main class="orm-entry" aria-labelledby="orm-title" style="--orm-primary: <?= htmlspecialchars($providerBranding['primary_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; --orm-secondary: <?= htmlspecialchars($providerBranding['secondary_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; --orm-surface: <?= htmlspecialchars($providerBranding['surface_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; --orm-text: <?= htmlspecialchars($providerBranding['text_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
      <style>
        .orm-entry { max-width: 980px; margin: 24px auto; padding: 0 16px; color: var(--orm-text); }
        .orm-entry h1 { display: flex; align-items: center; gap: 10px; margin: 0 0 20px; color: var(--orm-primary); font-size: 28px; }
        .orm-brand-icon { width: 40px; height: 40px; object-fit: contain; }
        .orm-entry a { color: var(--orm-secondary); }
        .orm-brand-footer { margin: 18px 0 0; color: #59677c; font-size: 13px; }
        .orm-card { padding: 24px; border: 1px solid #dce3ec; border-radius: 12px; background: var(--orm-surface); box-shadow: 0 4px 18px rgb(23 34 53 / 6%); }
        .orm-preflight-list { display: grid; gap: 8px; margin: 0; padding-left: 20px; }
        .orm-diagnostics { margin-top: 20px; }
        .orm-diagnostics-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 18px; }
        .orm-diagnostics-description { max-width: 640px; }
        .orm-diagnostics-privacy { flex: 0 1 250px; padding: 13px 15px; border: 1px solid #f3d0cc; border-radius: 9px; background: #fff9f8; color: #8f251d; font-size: 12px; line-height: 1.5; }
        .orm-diagnostics-privacy strong { display: block; margin-bottom: 3px; font-size: 13px; }
        .orm-diagnostics pre { max-height: 360px; overflow: auto; padding: 14px; border-radius: 8px; background: #f2f5f9; font-size: 13px; }
        .orm-diagnostics summary { cursor: pointer; font-weight: 700; }
        .orm-diagnostics-download { display: inline-block; margin-top: 14px; padding: 10px 14px; border-radius: 7px; background: #2855d9; color: #fff; font-weight: 700; text-decoration: none; }
        .orm-state { display: inline-block; margin: 0 0 18px; padding: 6px 12px; border-radius: 999px; background: #e9f7ef; color: #176b3a; font-weight: 700; text-transform: capitalize; }
        .orm-state.is-pending { background: #fff3d9; color: #895a00; }
        .orm-state.is-failed { background: #fde9e9; color: #a42828; }
        .orm-state.is-idle { background: #edf1f6; color: #4f6078; }
        .orm-metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(165px, 1fr)); gap: 12px; margin: 18px 0 24px; }
        .orm-metric { min-width: 0; padding: 14px; border: 1px solid #e2e8f0; border-radius: 9px; background: var(--orm-surface); }
        .orm-metric-label { display: flex; align-items: center; gap: 8px; color: #59677c; font-size: 13px; }
        .orm-metric-icon { width: 18px; height: 18px; color: #317a9d; }
        .orm-metric-value { display: block; margin-top: 8px; color: #172235; font-size: 20px; font-weight: 700; overflow-wrap: anywhere; }
        .orm-metrics-note { color: #59677c; font-size: 13px; }
        .orm-metrics-note.is-stale { padding: 10px 12px; border-left: 3px solid #b77813; border-radius: 4px; background: #fff6e5; color: #714b0b; }
        .orm-health { margin: 22px 0; }
        .orm-health-list { display: grid; gap: 10px; margin: 12px 0 0; padding: 0; list-style: none; }
        .orm-health-item { padding: 13px 15px; border: 1px solid #dce3ed; border-left: 4px solid #317a9d; border-radius: 8px; background: var(--orm-surface); }
        .orm-health-item.is-warning { border-left-color: #b77813; background: #fffaf0; }
        .orm-health-item.is-review { border-left-color: #317a9d; }
        .orm-health-item.is-info { border-left-color: #8795a8; }
        .orm-health-item strong { display: block; }
        .orm-health-item p { margin: 6px 0 0; }
        .orm-health-severity { display: inline-block; margin-right: 6px; color: #59677c; font-size: 11px; font-weight: 700; letter-spacing: .04em; text-transform: uppercase; }
        .orm-health-note { color: #59677c; font-size: 13px; }
        .orm-history { margin: 22px 0 18px; }
        .orm-history-header { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; }
        .orm-history-ranges { display: inline-flex; gap: 6px; }
        .orm-history-ranges a { padding: 7px 11px; border: 1px solid #cbd5e1; border-radius: 7px; color: #263b57; text-decoration: none; }
        .orm-history-ranges a[aria-current="true"] { border-color: #2855d9; background: #2855d9; color: #fff; }
        .orm-history-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
        .orm-history-chart { min-width: 0; padding: 14px; border: 1px solid #e2e8f0; border-radius: 9px; background: var(--orm-surface); }
        .orm-history-chart h4 { margin: 0 0 8px; color: #59677c; font-size: 13px; font-weight: 600; }
        .orm-history-chart strong { font-size: 20px; }
        .orm-history-chart svg { display: block; width: 100%; margin-top: 8px; }
        .orm-history-chart span { color: #59677c; font-size: 12px; }
        .orm-entry button { padding: 10px 16px; border: 0; border-radius: 7px; background: var(--orm-primary); color: #fff; font-weight: 700; cursor: pointer; }
        .orm-entry button:disabled { background: #e1e6ee; color: #738096; cursor: not-allowed; }
        .orm-actions { display: flex; gap: 12px; }
        .orm-preset-form, .orm-config-form { max-width: 640px; margin-top: 18px; }
        .orm-preset-form label, .orm-config-form label { display: block; margin-bottom: 7px; font-weight: 700; }
        .orm-preset-form select, .orm-config-form select, .orm-config-form input { width: 100%; padding: 10px 12px; border: 1px solid #bac6d5; border-radius: 7px; color: #172235; background: #fff; font: inherit; }
        .orm-config-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; margin: 14px 0; }
        .orm-config-grid label { margin: 0; }
        .orm-config-label { display: flex; align-items: center; gap: 8px; margin-bottom: 7px; }
        .orm-config-icon { width: 18px; height: 18px; color: #317a9d; }
        .orm-config-grid input, .orm-config-grid select { margin-top: 6px; }
        .orm-config-impact { padding: 12px; border-left: 3px solid #bf7a18; background: #fff8e9; color: #57390e; }
        .orm-preset-help { color: #59677c; font-size: 14px; }
        .orm-note { margin-top: 18px; color: #59677c; }
        .orm-setup-options { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 14px; margin: 18px 0; }
        .orm-setup-choice { display: block; padding: 18px; border: 1px solid #dce3ec; border-radius: 10px; background: #fff; color: var(--orm-text) !important; text-decoration: none; }
        .orm-setup-choice:hover, .orm-setup-choice:focus-visible { border-color: var(--orm-primary); outline: 2px solid color-mix(in srgb, var(--orm-primary) 28%, transparent); outline-offset: 2px; }
        .orm-setup-choice h3 { margin: 0 0 8px; }
        .orm-setup-choice p { margin: 0; color: #59677c; }
        .orm-setup-step { margin: 16px 0; padding: 14px 16px; border-left: 4px solid var(--orm-primary); border-radius: 6px; background: #f7f9fc; }
        .orm-setup-command { display: block; margin: 10px 0; padding: 12px; overflow-wrap: anywhere; border-radius: 6px; background: #172235; color: #fff; }
        .orm-setup-status { padding: 12px 14px; border: 1px solid #dce3ec; border-radius: 8px; background: #f7f9fc; }
        .orm-setup-links { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 16px; }
        .orm-setup-links a { font-weight: 700; }
        .orm-backup-list { display: grid; gap: 9px; max-width: 720px; margin: 16px 0 0; padding: 0; list-style: none; }
        .orm-backup-list li { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px 18px; padding: 12px 14px; border: 1px solid #dce3ed; border-radius: 8px; background: #fff; }
        .orm-backup-list a { font-weight: 700; }
        .orm-backup-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
        .orm-backup-actions form { margin: 0; }
        .orm-connection { margin-top: 18px; }
        .orm-connection dl { display: grid; grid-template-columns: minmax(150px, 190px) 1fr; gap: 10px 18px; }
        .orm-connection dt { color: #59677c; }
        .orm-connection dd { margin: 0; overflow-wrap: anywhere; }
        .orm-connection details { margin-top: 14px; }
        .orm-connection summary { cursor: pointer; font-weight: 700; }
        .orm-connection pre { overflow-x: auto; padding: 14px; border-radius: 8px; background: #f2f5f9; }
        .orm-copy-actions { display: flex; justify-content: flex-end; margin-top: 10px; }
        .orm-connection .orm-copy-button { padding: 7px 11px; border: 1px solid #cbd5e1; background: #fff; color: #263b57; font-size: 13px; }
        .orm-auth { margin: 20px 0; padding: 16px; border: 1px solid #d9e0e8; border-radius: 9px; background: #fbfcfe; }
        .orm-auth-secret { margin-top: 14px; padding: 14px; border: 1px solid #e0a39d; border-radius: 8px; background: #fff8f7; }
        .orm-auth-secret pre { overflow-wrap: anywhere; user-select: all; }
        .orm-auth-secret code { font-size: 15px; }
        .orm-copy-status:empty { display: none; }
        .orm-copy-status { color: #176b3a; }
        @media (max-width: 600px) { .orm-connection dl, .orm-config-grid { grid-template-columns: 1fr; gap: 8px; } .orm-diagnostics-head { display: block; } .orm-diagnostics-privacy { margin-top: 12px; } }
      </style>
      <h1 id="orm-title"><?php if ($providerBranding['logo_png_base64'] !== ''): ?><img class="orm-brand-icon" src="data:image/png;base64,<?= $providerBranding['logo_png_base64'] ?>" alt=""><?php else: ?><svg class="orm-brand-icon" viewBox="0 0 256 256" aria-hidden="true"><title>Open Redis Manager cache cube</title>
  <rect x="4" y="4" width="248" height="248" rx="58" fill="#D92D20"/><rect x="5" y="5" width="246" height="246" rx="57" fill="none" stroke="#FFF" stroke-opacity=".18" stroke-width="2"/>
  <path d="m128 47 67 37-67 37-67-37 67-37Z" fill="#FFF"/><path d="m61 84 67 37v67l-67-37V84Z" fill="#FFE5E1"/><path d="m128 121 67-37v67l-67 37v-67Z" fill="#FFF"/><path d="m128 63 39 21-39 22-39-22 39-21Z" fill="#D92D20"/><path d="m128 72 23 12-23 13-23-13 23-12Z" fill="#F9BDB6"/><path d="m68 128 60 32 60-32M68 140l60 32 60-32" fill="none" stroke="#D92D20" stroke-linecap="round" stroke-linejoin="round" stroke-width="8"/>
</svg><?php endif; ?><?= htmlspecialchars($providerBranding['product_name'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></h1>
      <?php if (!$brokerVerified): ?>
        <p role="alert">The account identity could not be verified by the local ORM broker. Reload the page or contact the server administrator.</p>
      <?php else: ?>
        <p>Verified cPanel account: <code><?= htmlspecialchars($account->username(), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></p>
        <section aria-labelledby="orm-ready-title">
          <h2 id="orm-ready-title">Your cache instance</h2>
          <?php if ($actionResult === null && ($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST'): ?>
            <p role="alert">The requested action was not accepted.</p>
          <?php elseif ($actionResult !== null && !$actionResult['success']): ?>
            <p role="alert"><?= htmlspecialchars($errorMessages[$actionResult['error'] ?? ''] ?? 'The action could not be completed. Contact your hosting provider.', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?><?php if (is_string($actionResult['safety_backup_id'] ?? null)): ?> Safety snapshot <?= htmlspecialchars($actionResult['safety_backup_id'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> was retained and is available in the backup list.<?php endif; ?></p>
          <?php elseif ($actionResult !== null): ?>
        <p role="status"><?php if ($action === 'configure'): ?>Configuration saved.<?php elseif ($action === 'auth.rotate'): ?>A new AUTH password is ready below. Set it in your applications now. If you rotated, the previous password is revoked.<?php elseif ($action === 'auth.disable'): ?>AUTH is disabled. Remove the password from your applications before reconnecting.<?php elseif ($action === 'backup.create' && is_array($actionResult['backup'] ?? null)): ?>Backup created: <?= htmlspecialchars($actionResult['backup']['id'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>.<?php elseif ($action === 'backup.restore'): ?>Restored snapshot <?= htmlspecialchars($actionResult['backup_id'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>. Safety snapshot <?= htmlspecialchars($actionResult['safety_backup_id'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> was created first; cache state: <?= htmlspecialchars($actionResult['state'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>.<?php else: ?>Action accepted.<?php endif; ?><?php if (isset($actionResult['state']) && $action !== 'backup.restore'): ?> Current state: <?= htmlspecialchars($actionResult['state'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>.<?php endif; ?><?php if (in_array($action, ['provision', 'configure'], true) && is_array($actionResult['policy_warnings'] ?? null) && $actionResult['policy_warnings'] !== []): ?> Provider policy warning: <?php $warningText = ['package_disabled' => 'this package is marked unavailable', 'memory_limit_exceeded' => 'the requested memory exceeds a package ceiling', 'client_limit_exceeded' => 'the requested client limit exceeds a package ceiling', 'reseller_instance_quota_exceeded' => 'the reseller instance limit has been reached', 'reseller_memory_quota_exceeded' => 'the reseller memory limit has been reached', 'reseller_usage_unavailable' => 'the current reseller usage could not be verified']; ?><?= htmlspecialchars(implode('; ', array_map(static fn (string $warning): string => $warningText[$warning] ?? 'a provider policy condition', $actionResult['policy_warnings'])), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>.<?php endif; ?></p>
          <?php endif; ?>
          <?php if ($downloadFailure): ?>
            <p role="alert">The requested backup is unavailable or failed file validation.</p>
          <?php endif; ?>
          <?php if ($instanceStatus === null || !$instanceStatus['success']): ?>
            <p role="alert">The local ORM service is temporarily unavailable. Contact the server administrator.</p>
          <?php else: ?>
            <div class="orm-card">
            <p class="orm-state <?= htmlspecialchars($stateClass, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>"><?= htmlspecialchars(ucwords(str_replace('_', ' ', $instanceStatus['state'])), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
            <?php if ($instanceStatus['state'] !== 'not_configured' && $authConfigured === null): ?>
              <p role="alert">ORM could not verify this instance's AUTH state. Connection helpers and password controls are hidden until the broker is available.</p>
            <?php endif; ?>
            <?php if (!empty($instanceStatus['preset'])): ?>
              <p class="orm-note">Setup preset: <strong><?= htmlspecialchars(ucfirst($instanceStatus['preset']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong></p>
            <?php endif; ?>
            <section aria-labelledby="orm-preflight-title">
              <h3 id="orm-preflight-title">Setup preflight</h3>
              <ul class="orm-preflight-list">
                <li><strong>Cache instance:</strong> <?= $instanceStatus['state'] === 'not_configured' ? 'Not initialized — initialize it before connecting an application.' : 'Initialized.' ?></li>
                <li><strong>Cache service:</strong> <?= match ($instanceStatus['state']) {
                    'running' => 'Running.',
                    'starting' => 'Starting.',
                    'stopping' => 'Stopping.',
                    'stopped' => 'Stopped — start it before connecting an application.',
                    'failed' => 'Failed — check the service status before connecting an application.',
                    default => 'Not configured — initialize the cache before connecting an application.',
                } ?></li>
                <li><strong>Connection details:</strong> <?= $connectionDetails !== null ? 'Available for this cPanel account.' : 'Available after the cache is initialized.' ?></li>
                <li><strong>Application connection:</strong> Not verified. ORM does not read application configuration or test an application runtime.</li>
              </ul>
              <h4>Application discovery</h4>
              <p class="orm-note">On demand, ORM checks fixed marker paths in your cPanel domain roots. It does not read file contents, configuration, secrets, or change application files. Results identify possible applications only; they do not confirm an active Redis integration.</p>
              <p><a href="?orm_app_scan=run">Scan for common applications</a></p>
              <?php if ($applicationScan !== null): ?>
                <?php if (!$applicationScan['available']): ?>
                  <p role="status">Application discovery is unavailable in this cPanel runtime. No files were scanned.</p>
                <?php elseif ($applicationScan['roots_inspected'] === 0): ?>
                  <p role="status">No safe domain roots were available to scan.</p>
                <?php elseif ($applicationScan['applications'] === []): ?>
                  <p role="status">Scan complete. No supported application markers were found in the inspected domain roots.</p>
                <?php else: ?>
                  <p role="status">Possible applications found. Their connection status remains unverified:</p>
                  <ul><?php foreach ($applicationScan['applications'] as $application): ?><li><?= htmlspecialchars($application, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></li><?php endforeach; ?></ul>
                <?php endif; ?>
                <?php if ($applicationScan['truncated']): ?>
                  <p class="orm-note" role="status">The scan reached a safety limit. Results may be incomplete.</p>
                <?php endif; ?>
              <?php endif; ?>
            </section>
            <?php if ($podmanCaches !== []): ?>
              <section class="orm-card" aria-labelledby="orm-podman-title">
                <h3 id="orm-podman-title">Existing cPanel Podman caches</h3>
                <p>These are existing Redis or Valkey containers owned by this cPanel account. cPanel’s EA Podman tools remain responsible for them. ORM can start, stop, or restart an existing container; it cannot install, remove, upgrade, or reconfigure containers.</p>
                <?php if ($podmanActionMessage !== null): ?><p role="status"><?= htmlspecialchars($podmanActionMessage, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p><?php endif; ?>
                <?php foreach ($podmanCaches as $podmanIndex => $podmanCache): ?>
                  <?php $podmanDetails = \Orm\Cpanel\ConnectionDetails::forSocket($account->username(), $podmanCache['socket_path']); ?>
                  <?php if ($podmanDetails !== null): ?>
                    <article class="orm-preset-card">
                      <h4><?= htmlspecialchars(ucfirst($podmanCache['backend']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> · cPanel container <?= htmlspecialchars($podmanCache['container'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></h4>
                      <p><strong>Status:</strong> <?= htmlspecialchars(ucfirst(str_replace('-', ' ', $podmanCache['status'])), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?><?= $podmanCache['version'] !== null ? ' · version ' . htmlspecialchars($podmanCache['version'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') : '' ?></p>
                      <p><strong>Private socket:</strong> <code><?= htmlspecialchars($podmanCache['socket_path'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></p>
                      <?php if ($podmanCache['status'] === 'socket-missing'): ?>
                        <p class="orm-note">The container is installed for this account, but its socket is absent. Start it before using the connection examples.</p>
                      <?php elseif ($podmanCache['status'] === 'reachable'): ?>
                        <p class="orm-note">The PHP runtime completed a bounded, read-only PING. No keys or values were read.</p>
                      <?php elseif ($podmanCache['status'] === 'unavailable'): ?>
                        <p class="orm-note">The account-owned socket exists, but the read-only health probe could not connect. Check the container in cPanel before using it.</p>
                      <?php else: ?>
                        <p class="orm-note">The account-owned socket exists, but the read-only PING did not confirm a response. Check the container in cPanel before using it.</p>
                      <?php endif; ?>
                      <form method="post" class="orm-inline-form">
                        <input type="hidden" name="orm_podman_container" value="<?= htmlspecialchars($podmanCache['container'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                        <?php if ($podmanCache['status'] === 'socket-missing'): ?>
                          <button type="submit" name="orm_podman_action" value="start">Start container</button>
                        <?php else: ?>
                          <button type="submit" name="orm_podman_action" value="restart">Restart container</button>
                          <button type="submit" name="orm_podman_action" value="stop">Stop container</button>
                        <?php endif; ?>
                      </form>
                      <details>
                        <summary>PHP with PhpRedis</summary>
                        <pre><code><?= htmlspecialchars($podmanDetails['php_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                      </details>
                      <details>
                        <summary>Laravel</summary>
                        <pre><code><?= htmlspecialchars($podmanDetails['laravel_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                      </details>
                      <details>
                        <summary>WordPress / WooCommerce</summary>
                        <pre><code><?= htmlspecialchars($podmanDetails['wordpress_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                      </details>
                      <details>
                        <summary>LiteSpeed Cache</summary>
                        <pre><code><?= htmlspecialchars($podmanDetails['litespeed_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                      </details>
                      <details>
                        <summary>Magento / Adobe Commerce</summary>
                        <pre><code><?= htmlspecialchars($podmanDetails['magento_values'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                      </details>
                      <details>
                        <summary>Node.js with node-redis</summary>
                        <pre><code><?= htmlspecialchars($podmanDetails['node_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                      </details>
                      <details>
                        <summary>Python with redis-py</summary>
                        <pre><code><?= htmlspecialchars($podmanDetails['python_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                      </details>
                      <p class="orm-note">The cPanel Redis and Valkey container packages require a normal, non-jailed shell account. <a href="https://docs.cpanel.net/ea4/containers/redis-via-containers/">Redis guide</a> · <a href="https://docs.cpanel.net/ea4/containers/valkey-via-containers/">Valkey guide</a>.</p>
                    </article>
                  <?php endif; ?>
                <?php endforeach; ?>
              </section>
            <?php endif; ?>
            <section class="orm-health" aria-labelledby="orm-health-title" aria-live="polite">
              <h3 id="orm-health-title">Health guidance <span class="orm-health-severity">Advisory</span></h3>
              <ul class="orm-health-list">
                <?php foreach ($healthGuidance['findings'] as $finding): ?>
                  <li class="orm-health-item is-<?= htmlspecialchars($finding['severity'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                    <span class="orm-health-severity"><?= htmlspecialchars($finding['severity'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></span>
                    <strong><?= htmlspecialchars($finding['title'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong>
                    <p><?= htmlspecialchars($finding['detail'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
                    <p><strong>Suggested next step:</strong> <?= htmlspecialchars($finding['recommendation'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
                  </li>
                <?php endforeach; ?>
              </ul>
              <p class="orm-health-note">Guidance uses current account metrics and fixed thresholds. It does not test application connectivity or guarantee cache performance.</p>
            </section>
            <?php if ($instanceStatus['state'] !== 'not_configured'): ?>
              <?php if ($developerExposure): ?>
              <section aria-labelledby="orm-usage-title">
                <h3 id="orm-usage-title">Usage metrics</h3>
                <?php if ($hasLiveMetrics): ?>
                  <div class="orm-metrics">
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="3" width="16" height="18" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 8h8M8 12h8M8 16h5" stroke="currentColor" stroke-width="2"/></svg>Memory used</span><strong class="orm-metric-value"><?= htmlspecialchars($formatBytes($liveMetrics['memory_used_bytes']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 19V5m0 14h16M7 15l4-4 3 2 5-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>Memory peak</span><strong class="orm-metric-value"><?= htmlspecialchars($formatBytes($liveMetrics['memory_peak_bytes']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M17 5a3 3 0 0 1 0 6m1 3a5 5 0 0 1 3 4v2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>Connected clients</span><strong class="orm-metric-value"><?= number_format($liveMetrics['connected_clients']) ?></strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 7v5l3 2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>Uptime</span><strong class="orm-metric-value"><?= number_format($uptimeDays) ?>d <?= str_pad((string) $uptimeHours, 2, '0', STR_PAD_LEFT) ?>h</strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 18h3l3-7 4 4 3-8h3" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>Operations per second</span><strong class="orm-metric-value"><?= number_format($liveMetrics['commands_per_second']) ?>/s</strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12l4 4L19 6" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></svg>Cache hit ratio</span><strong class="orm-metric-value"><?= htmlspecialchars($hitRatio, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong></div>
                  </div>
                  <p class="orm-metrics-note<?= $liveMetrics['stale'] ? ' is-stale' : '' ?>" role="status">
                    <strong><?= $liveMetrics['stale'] ? 'Stale sample' : 'Current sample' ?>.</strong>
                    Captured <?= htmlspecialchars(gmdate('Y-m-d H:i:s', $liveMetrics['sampled_at']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> UTC.
                    <?php if ($liveMetrics['stale'] || $liveMetrics['retained']): ?>
                      This latest sample is saved for up to 30 days.
                    <?php else: ?>
                      This live sample could not be saved for fallback use.
                    <?php endif; ?>
                  </p>
                  <div class="orm-history">
                    <div class="orm-history-header">
                      <h4>Hourly history</h4>
                      <nav class="orm-history-ranges" aria-label="Metrics history range">
                        <a href="?orm_metrics_range=24h"<?= $historyRange === '24h' ? ' aria-current="true"' : '' ?>>24 hours</a>
                        <a href="?orm_metrics_range=7d"<?= $historyRange === '7d' ? ' aria-current="true"' : '' ?>>7 days</a>
                      </nav>
                    </div>
                    <?php if (is_array($metricsHistory) && ($metricsHistory['success'] ?? false) === true && $metricsHistory['history'] !== []): ?>
                      <div class="orm-history-grid">
                        <?php $renderHistoryChart($metricsHistory['history'], 'memory_used_bytes', 'Memory used', '#d92d20'); ?>
                        <?php $renderHistoryChart($metricsHistory['history'], 'connected_clients', 'Connected clients', '#317a9d'); ?>
                        <?php $renderHistoryChart($metricsHistory['history'], 'keyspace_hits', 'Cache hit ratio', '#16804a', true); ?>
                      </div>
                      <p class="orm-metrics-note" role="status">Hourly samples are collected while your cache is running. New instances use the history retention set by your hosting provider.</p>
                    <?php elseif (is_array($metricsHistory) && ($metricsHistory['success'] ?? false) === true): ?>
                      <p class="orm-metrics-note" role="status">No hourly samples are available for this range yet. Collection runs while your cache is active<?= $metricsHistory['scheduled'] ? '.' : '; scheduled collection is currently unavailable.' ?></p>
                    <?php else: ?>
                      <p class="orm-metrics-note" role="status">Hourly history is temporarily unavailable. The current usage sample is shown above when available.</p>
                    <?php endif; ?>
                  </div>
                <?php else: ?>
                  <p class="orm-metrics-note" role="status">No recent usage sample is available. ORM could not return live metrics or a saved sample.</p>
                <?php endif; ?>
              </section>
              <?php endif; ?>
              <?php if ($advancedExposure): ?>
              <section aria-labelledby="orm-backups-title">
                <h3 id="orm-backups-title">Backups</h3>
                <p class="orm-note">Create an RDB snapshot while the cache stays online. Restoring briefly stops the cache and replaces its data with the selected snapshot; writes made after that snapshot may be lost. ORM creates a safety snapshot before restore. The transfer may use extra CPU and disk I/O. The hosting provider's retention limit is applied when you create a new snapshot.</p>
                <form method="post" class="orm-preset-form">
                  <input type="hidden" name="orm_action" value="backup.create">
                  <button type="submit"<?= $instanceStatus['state'] === 'running' ? '' : ' disabled' ?>>Create backup</button>
                </form>
                <?php if (is_array($backupList) && ($backupList['success'] ?? false) === true): ?>
                  <?php if ($backupList['backups'] === []): ?>
                    <p class="orm-note">No backups have been created for this cache.</p>
                  <?php else: ?>
                    <ul class="orm-backup-list">
                      <?php foreach ($backupList['backups'] as $backup): ?>
                        <li>
                          <span><?= htmlspecialchars(gmdate('Y-m-d H:i:s', $backup['created_at']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> UTC · <?= htmlspecialchars($formatBytes($backup['size_bytes']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></span>
                          <div class="orm-backup-actions">
                            <a href="?orm_backup=<?= rawurlencode($backup['id']) ?>">Download backup</a>
                            <form method="post" onsubmit="return confirm('Restore this snapshot? The cache will restart briefly, writes newer than this snapshot may be lost, and ORM will create a safety snapshot first.');">
                              <input type="hidden" name="orm_action" value="backup.restore">
                              <input type="hidden" name="orm_backup_id" value="<?= htmlspecialchars($backup['id'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                              <button type="submit"<?= $instanceStatus['state'] === 'running' ? '' : ' disabled' ?>>Restore</button>
                            </form>
                          </div>
                        </li>
                      <?php endforeach; ?>
                    </ul>
                  <?php endif; ?>
                <?php else: ?>
                  <p class="orm-note" role="status">Backup inventory is temporarily unavailable.</p>
                <?php endif; ?>
              </section>
              <?php endif; ?>
            <?php endif; ?>
            <?php if ($instanceStatus['state'] === 'not_configured'): ?>
              <?php if ($showSetupWizard): ?>
                <section class="orm-card" aria-labelledby="orm-setup-title">
                  <h3 id="orm-setup-title">First-time setup</h3>
                  <p>Choose where this account’s Redis-compatible cache should run. ORM checks the selected path and guides you through the required setup.</p>
                  <?php if ($setupMode === 'choose'): ?>
                    <div class="orm-setup-options">
                      <a class="orm-setup-choice" href="?orm_setup=native" aria-label="Choose a native Redis or Valkey service">
                        <h3>Native service</h3>
                        <p>Use an ORM-managed Redis/Valkey process installed on the server. WHM controls which backend is approved for new instances.</p>
                      </a>
                      <a class="orm-setup-choice" href="?orm_setup=podman" aria-label="Choose a cPanel EA Podman container">
                        <h3>cPanel EA Podman</h3>
                        <p>Install a cPanel-provided Redis 6.2 or Valkey 7.2 container under this cPanel account.</p>
                      </a>
                    </div>
                    <p class="orm-note">If a cache is already installed for your account, it appears in the existing cPanel Podman section above.</p>
                  <?php elseif ($setupMode === 'native'): ?>
                    <h4>Native service readiness</h4>
                    <?php if (($nativeDiscovery['status'] ?? null) !== 'supported-platform'): ?>
                      <p class="orm-setup-status" role="status">Host discovery is unavailable or this platform is unsupported. Ask your hosting administrator to verify a supported Linux Redis/Valkey package and the WHM backend selection.</p>
                    <?php else: ?>
                      <?php $detectedNativeBackends = array_values(array_filter($nativeDiscovery['backends'], static fn (array $backend): bool => ($backend['status'] ?? null) === 'detected')); ?>
                      <?php if ($detectedNativeBackends === []): ?>
                        <p class="orm-setup-status" role="status">No Redis/Valkey server binary was found in ORM’s standard locations. That does not prove the host has no Redis-compatible service; ask your administrator to verify the package and WHM backend selection.</p>
                      <?php else: ?>
                        <p class="orm-setup-status" role="status">Host binary discovery found:</p>
                        <ul>
                          <?php foreach ($detectedNativeBackends as $backend): ?>
                            <li><strong><?= htmlspecialchars($backend['label'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong><?= is_string($backend['version'] ?? null) ? ' ' . htmlspecialchars($backend['version'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') : '' ?> — <?= htmlspecialchars($backend['server_binary'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></li>
                          <?php endforeach; ?>
                        </ul>
                      <?php endif; ?>
                      <p>New ORM-managed native instances use the default backend selected by your hosting provider in WHM. This page cannot install host packages or change that provider setting.</p>
                      <?php if ($detectedNativeBackends !== []): ?>
                      <form method="post" class="orm-preset-form">
                        <input type="hidden" name="orm_action" value="provision">
                        <?php if (!$developerExposure): ?>
                        <input type="hidden" name="orm_preset" value="generic">
                        <p class="orm-preset-help">The standard profile uses a private socket, a 64 MiB memory cap, and no persistence.</p>
                        <?php else: ?>
                        <label for="orm-preset">Configuration preset</label>
                        <select id="orm-preset" name="orm_preset" required>
                          <option value="generic" selected>Generic — 64 MiB</option>
                          <option value="wordpress">WordPress — 48 MiB</option>
                          <option value="laravel">Laravel — 32 MiB</option>
                          <option value="magento">Magento — 64 MiB</option>
                          <option value="session">Session cache — 32 MiB</option>
                        </select>
                        <p class="orm-preset-help">The host applies package memory/client limits and provider defaults. ORM keeps this service account-scoped.</p>
                        <?php endif; ?>
                        <button type="submit">Initialize native cache</button>
                      </form>
                      <?php else: ?>
                        <p>Once your administrator installs a supported native Redis/Valkey server package and selects it in WHM, choose <a href="?orm_setup=native">Check again</a>.</p>
                      <?php endif; ?>
                    <?php endif; ?>
                    <div class="orm-setup-links"><a href="?orm_setup=choose">Back to setup choices</a></div>
                  <?php else: ?>
                    <h4>cPanel EA Podman readiness</h4>
                    <?php if (($podmanSetup['status'] ?? null) === 'ea-podman-unavailable'): ?>
                      <p class="orm-setup-status" role="status">The cPanel EA Podman tool is not available to this account. Ask your hosting administrator to enable EasyApache 4 containers, confirm the server is supported, and enable user namespaces. CloudLinux/CageFS container setups are not supported by cPanel’s EA Podman integration.</p>
                    <?php elseif (($podmanSetup['status'] ?? null) === 'unsupported-host'): ?>
                      <p class="orm-setup-status" role="status">This host is identified as <?= htmlspecialchars($podmanSetup['host_platform'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>, which cPanel does not support for EA Podman Redis/Valkey containers. Choose the native service option or ask your administrator about supported host alternatives.</p>
                    <?php elseif (($podmanSetup['status'] ?? null) === 'unsupported-shell'): ?>
                      <p class="orm-setup-status" role="status">This account does not have a normal, non-jailed shell. Ask your hosting administrator to enable Normal Shell before using EA Podman.</p>
                    <?php elseif (($podmanSetup['status'] ?? null) === 'checked'): ?>
                      <p class="orm-setup-status" role="status">The account’s EA Podman package inventory was checked. Host platform: <?= htmlspecialchars($podmanSetup['host_platform'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>. <?php if ($podmanSetup['host_platform'] === 'unknown'): ?>The operating system could not be verified; ask the administrator to confirm it is AlmaLinux, Rocky Linux, or Ubuntu.<?php endif; ?></p>
                      <?php foreach (['redis' => ['label' => 'Redis 6.2', 'package' => 'ea-redis62'], 'valkey' => ['label' => 'Valkey 7.2', 'package' => 'ea-valkey72']] as $backendId => $packageInfo): ?>
                        <div class="orm-setup-step">
                          <h4><?= htmlspecialchars($packageInfo['label'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></h4>
                          <?php if (($podmanSetup[$backendId] ?? null) === 'available'): ?>
                            <?php if (in_array($podmanSetup['host_platform'], ['AlmaLinux', 'Rocky Linux', 'Ubuntu'], true)): ?>
                            <p>This fixed cPanel package is advertised for this account. In cPanel Terminal or SSH as this account, run:</p>
                            <code class="orm-setup-command">/usr/local/cpanel/scripts/ea-podman install <?= htmlspecialchars($packageInfo['package'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code>
                            <p>After it completes, return here and refresh. ORM will verify the account-owned container and socket.</p>
                            <?php else: ?>
                              <p>This fixed package is advertised, but the host operating system could not be verified. Ask the administrator to confirm the supported host and user-namespace prerequisites before installing.</p>
                            <?php endif; ?>
                          <?php elseif (($podmanSetup[$backendId] ?? null) === 'not-listed'): ?>
                            <p>This package was not listed in the account inventory. Ask the administrator to confirm that the corresponding EasyApache container package is installed and available on the host.</p>
                          <?php else: ?>
                            <p>Package availability could not be confirmed. Ask the administrator to verify the host prerequisites before installing.</p>
                          <?php endif; ?>
                        </div>
                      <?php endforeach; ?>
                    <?php else: ?>
                      <p class="orm-setup-status" role="status">ORM could not verify EA Podman package availability for this account. The result is unknown; it does not mean Redis or Valkey is absent. Check account shell access and ask the administrator to verify the host setup.</p>
                    <?php endif; ?>
                    <p>cPanel EA Podman requires a supported AlmaLinux, Rocky Linux, or Ubuntu host with EasyApache 4 containers and user namespaces enabled. ORM does not probe the kernel namespace policy; the administrator must verify that prerequisite. ORM will not run a host package manager or accept custom images, package names, or shell commands.</p>
                    <div class="orm-setup-links">
                      <a href="?orm_setup=podman">Check again</a>
                      <a href="https://docs.cpanel.net/ea4/containers/easyapache-4-containers/" target="_blank" rel="noopener noreferrer">Administrator setup guide</a>
                      <a href="?orm_setup=choose">Back to setup choices</a>
                    </div>
                  <?php endif; ?>
                </section>
              <?php elseif ($podmanCaches !== []): ?>
                <p>An existing cPanel EA Podman cache is shown above. ORM-managed native service setup is not initialized for this account.</p>
              <?php elseif (($podmanInventory['status'] ?? null) === 'unavailable'): ?>
                <p class="orm-setup-status" role="status">ORM could not safely verify this account’s cPanel container inventory. It will not assume a cache is absent. Contact your hosting administrator to check the account’s EA Podman setup.</p>
              <?php else: ?>
                <p>Your account has no initialized ORM cache. Return to the first-time setup page after confirming your host backend selection.</p>
              <?php endif; ?>
            <?php else: ?>
              <?php if ($developerExposure && in_array($instanceStatus['state'], ['running', 'stopped', 'failed'], true) && is_array($instanceStatus['config'] ?? null)): ?>
                <section aria-labelledby="orm-config-title">
                  <h3 id="orm-config-title">Configuration</h3>
                  <form method="post" class="orm-config-form">
                    <input type="hidden" name="orm_action" value="configure">
                    <div class="orm-config-grid">
                      <label for="orm-memory-mib"><span class="orm-config-label"><svg class="orm-config-icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="16" height="16" rx="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 9h8M8 13h5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>Memory limit (MiB)</span>
                        <input id="orm-memory-mib" name="orm_memory_mib" type="number" min="8" max="64" step="1" required value="<?= htmlspecialchars((string) $instanceStatus['config']['memory_mib'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                      </label>
                      <p class="orm-note">Your hosting package may enforce a lower memory ceiling than the maximum shown here.</p>
                      <label for="orm-maxmemory-policy"><span class="orm-config-label"><svg class="orm-config-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 5h14M5 12h14M5 19h14" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="9" cy="5" r="2" fill="#fff" stroke="currentColor" stroke-width="2"/><circle cx="15" cy="12" r="2" fill="#fff" stroke="currentColor" stroke-width="2"/><circle cx="11" cy="19" r="2" fill="#fff" stroke="currentColor" stroke-width="2"/></svg>When the cache is full</span>
                        <select id="orm-maxmemory-policy" name="orm_maxmemory_policy" required>
                          <?php foreach (['allkeys-lru' => 'Evict least recently used keys', 'allkeys-lfu' => 'Evict least frequently used keys', 'allkeys-random' => 'Evict random keys', 'volatile-lru' => 'Evict least recently used expiring keys', 'volatile-lfu' => 'Evict least frequently used expiring keys', 'volatile-random' => 'Evict random expiring keys', 'volatile-ttl' => 'Evict expiring keys with the shortest TTL', 'noeviction' => 'Reject writes when full'] as $policy => $label): ?>
                            <option value="<?= htmlspecialchars($policy, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>"<?= $instanceStatus['config']['maxmemory_policy'] === $policy ? ' selected' : '' ?>><?= htmlspecialchars($label, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></option>
                          <?php endforeach; ?>
                        </select>
                      </label>
                      <label for="orm-maxclients"><span class="orm-config-label"><svg class="orm-config-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M17 5a3 3 0 0 1 0 6m1 3a5 5 0 0 1 3 4v2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>Maximum connected clients</span>
                        <input id="orm-maxclients" name="orm_maxclients" type="number" min="10" max="100" step="1" required value="<?= htmlspecialchars((string) $instanceStatus['config']['maxclients'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                      </label>
                      <label for="orm-timeout"><span class="orm-config-label"><svg class="orm-config-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 7v5l3 2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>Close idle clients after (seconds)</span>
                        <input id="orm-timeout" name="orm_timeout" type="number" min="0" max="300" step="1" required value="<?= htmlspecialchars((string) $instanceStatus['config']['timeout'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                      </label>
                    </div>
                    <p class="orm-config-impact"><strong>Lowering memory can evict cached keys immediately; those evictions cannot be undone.</strong> The memory limit cannot exceed 64 MiB. TCP access, persistence, database count, and socket path remain controlled by the host.</p>
                    <p class="orm-preset-help">Changes apply live without restarting a running cache, then are saved for the next start. When stopped, changes are saved and applied on start. Package-specific ceilings are not available in this build.</p>
                    <button type="submit">Save configuration</button>
                  </form>
                </section>
              <?php elseif ($developerExposure && in_array($instanceStatus['state'], ['starting', 'stopping'], true)): ?>
                <p class="orm-note">Configuration editing is unavailable while the cache is changing state.</p>
              <?php endif; ?>
              <div class="orm-actions">
                <form method="post">
                  <input type="hidden" name="orm_action" value="start">
                  <button type="submit"<?= in_array($instanceStatus['state'], ['running', 'starting'], true) ? ' disabled' : '' ?>>Start</button>
                </form>
                <form method="post">
                  <input type="hidden" name="orm_action" value="stop">
                  <button type="submit"<?= in_array($instanceStatus['state'], ['stopped', 'stopping'], true) ? ' disabled' : '' ?>>Stop</button>
                </form>
              </div>
              <p class="orm-note">Stopping the cache disconnects application clients until you start it again.</p>
              <?php if ($connectionDetails !== null): ?>
                <section class="orm-connection" aria-labelledby="orm-connection-title">
                  <h3 id="orm-connection-title">Connection details</h3>
                  <dl>
                    <dt>Endpoint</dt><dd>Private Unix socket</dd>
                    <dt>Socket path</dt><dd><code><?= htmlspecialchars($connectionDetails['socket_path'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></dd>
                    <dt>Default database</dt><dd><?= htmlspecialchars((string) $connectionDetails['database'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></dd>
                    <dt>Authentication</dt><dd><?= $authConfigured ? 'Redis AUTH password and account-private socket permissions.' : 'Account-private socket permissions; Redis AUTH is off.' ?></dd>
                  </dl>
                  <p class="orm-note">Only processes running as this cPanel account can access the socket. TCP is disabled. Confirm that the PHP runtime used by your site can see this path, especially if CageFS is enabled.</p>
                  <section class="orm-auth" aria-labelledby="orm-auth-title">
                    <h4 id="orm-auth-title">Redis AUTH password</h4>
                    <p><strong>Status:</strong> <?= $authConfigured ? 'Enabled' : 'Disabled' ?></p>
                    <p class="orm-note">Enabling or rotating the password restarts the cache and disconnects clients briefly. The password is generated by ORM and shown only in the response to this action. If you lose it, rotate it again. Code running as your cPanel account can access its own cache and credential.</p>
                    <form method="post" class="orm-preset-form">
                      <input type="hidden" name="orm_action" value="auth.rotate">
                      <button type="submit"<?= $instanceStatus['state'] === 'running' ? '' : ' disabled' ?>><?= $authConfigured ? 'Rotate AUTH password' : 'Enable AUTH and generate password' ?></button>
                    </form>
                    <?php if ($authConfigured): ?>
                      <form method="post" class="orm-preset-form" onsubmit="return confirm('Disable Redis AUTH? Applications with a configured password must remove it before reconnecting. The cache will restart briefly.');">
                        <input type="hidden" name="orm_action" value="auth.disable">
                        <button type="submit"<?= $instanceStatus['state'] === 'running' ? '' : ' disabled' ?>>Disable AUTH</button>
                      </form>
                    <?php endif; ?>
                    <?php if ($rotatedSecret !== null): ?>
                      <div class="orm-auth-secret" aria-labelledby="orm-auth-secret-label">
                        <p id="orm-auth-secret-label"><strong>New password · shown once</strong></p>
                        <pre><code id="orm-rotated-secret"><?= htmlspecialchars($rotatedSecret, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                        <button class="orm-copy-button" type="button" aria-label="Copy the new Redis AUTH password" data-copy-target="orm-rotated-secret" data-copy-label="Redis AUTH password">Copy password</button>
                      </div>
                    <?php endif; ?>
                  </section>
                  <p class="orm-note">These helpers copy connection settings only. They do not edit application files or enable caching, sessions, or queues.</p>
                  <details open>
                    <summary>PHP with PhpRedis</summary>
                    <div class="orm-copy-actions"><button class="orm-copy-button" type="button" aria-label="Copy PHP with PhpRedis example" data-copy-target="orm-example-php" data-copy-label="PHP with PhpRedis">Copy example</button></div>
                    <pre><code id="orm-example-php"><?= htmlspecialchars($connectionDetails['php_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                  </details>
                  <?php if ($developerExposure): ?>
                  <details>
                    <summary>WordPress and WooCommerce · Redis Object Cache</summary>
                    <div class="orm-copy-actions"><button class="orm-copy-button" type="button" aria-label="Copy WordPress and WooCommerce example" data-copy-target="orm-example-wordpress" data-copy-label="WordPress and WooCommerce">Copy settings</button></div>
                    <pre><code id="orm-example-wordpress"><?= htmlspecialchars($connectionDetails['wordpress_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                    <p class="orm-note">Requires a compatible object-cache plugin. WooCommerce uses the same WordPress object cache; test checkout and cart invalidation before enabling broadly.</p>
                  </details>
                  <details>
                    <summary>LiteSpeed Cache for WordPress</summary>
                    <div class="orm-copy-actions"><button class="orm-copy-button" type="button" aria-label="Copy LiteSpeed Cache settings" data-copy-target="orm-example-litespeed" data-copy-label="LiteSpeed Cache">Copy settings</button></div>
                    <pre><code id="orm-example-litespeed"><?= htmlspecialchars($connectionDetails['litespeed_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                    <p class="orm-note">In LiteSpeed Cache, choose Cache → Object. Confirm your installed version supports Redis over a Unix socket and that the selected PHP runtime can access it.</p>
                  </details>
                  <details>
                    <summary>Laravel</summary>
                    <div class="orm-copy-actions"><button class="orm-copy-button" type="button" aria-label="Copy Laravel environment settings" data-copy-target="orm-example-laravel" data-copy-label="Laravel">Copy settings</button></div>
                    <pre><code id="orm-example-laravel"><?= htmlspecialchars($connectionDetails['laravel_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                    <p class="orm-note">Configure cache, session, queue, and rate-limit features independently in your app; these environment values only identify the connection.</p>
                  </details>
                  <details>
                    <summary>Magento / Adobe Commerce</summary>
                    <div class="orm-copy-actions"><button class="orm-copy-button" type="button" aria-label="Copy Magento connection values" data-copy-target="orm-example-magento" data-copy-label="Magento / Adobe Commerce">Copy values</button></div>
                    <pre><code id="orm-example-magento"><?= htmlspecialchars($connectionDetails['magento_values'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                    <p class="orm-note">Use the official configuration command for your exact Commerce release and deployment type. Redis/Valkey backend names change by version; use distinct databases for cache, page cache, and sessions where enabled.</p>
                  </details>
                  <details>
                    <summary>Node.js with node-redis</summary>
                    <div class="orm-copy-actions"><button class="orm-copy-button" type="button" aria-label="Copy Node.js with node-redis example" data-copy-target="orm-example-node" data-copy-label="Node.js with node-redis">Copy example</button></div>
                    <pre><code id="orm-example-node"><?= htmlspecialchars($connectionDetails['node_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                  </details>
                  <details>
                    <summary>Python with redis-py</summary>
                    <div class="orm-copy-actions"><button class="orm-copy-button" type="button" aria-label="Copy Python with redis-py example" data-copy-target="orm-example-python" data-copy-label="Python with redis-py">Copy example</button></div>
                    <pre><code id="orm-example-python"><?= htmlspecialchars($connectionDetails['python_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
                  </details>
                  <?php endif; ?>
                  <p id="orm-copy-status" class="orm-note orm-copy-status" role="status" aria-live="polite"></p>
                  <script>
                    (() => {
                      const status = document.getElementById('orm-copy-status');
                      const oneTimeSecret = document.getElementById('orm-rotated-secret');
                      if (oneTimeSecret) window.addEventListener('pagehide', () => { oneTimeSecret.textContent = ''; });
                      document.querySelectorAll('.orm-copy-button').forEach(button => {
                        button.addEventListener('click', async () => {
                          const example = document.getElementById(button.dataset.copyTarget);
                          if (!example) {
                            status.textContent = 'This example is unavailable. Select and copy it manually.';
                            return;
                          }
                          try {
                            if (!navigator.clipboard?.writeText) throw new Error('clipboard unavailable');
                            await navigator.clipboard.writeText(example.innerText);
                            status.textContent = `${button.dataset.copyLabel} copied.`;
                          } catch {
                            status.textContent = 'Clipboard access is unavailable. Select and copy the example manually.';
                          }
                        });
                      });
                    })();
                  </script>
                </section>
              <?php endif; ?>
              <p class="orm-note">WHM fleet backups and restore are not enabled in this build.</p>
            <?php endif; ?>
            </div>
          <?php endif; ?>
        </section>
        <?php if ($developerExposure): ?>
        <section class="orm-card orm-diagnostics" aria-labelledby="orm-diagnostics-title">
          <div class="orm-diagnostics-head">
            <div class="orm-diagnostics-description">
              <h2 id="orm-diagnostics-title">Support diagnostics</h2>
              <p class="orm-note">Preview or download a small JSON report of this account's ORM instance. It is generated in memory and is not stored by ORM.</p>
            </div>
            <aside class="orm-diagnostics-privacy"><strong>Privacy built in</strong>No account names, paths, credentials, keys, values, app content, sessions, logs, or command output.</aside>
          </div>
          <details>
            <summary>Preview diagnostics JSON</summary>
            <pre><?= htmlspecialchars($diagnosticJson, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></pre>
          </details>
          <a class="orm-diagnostics-download" href="?orm_diagnostics=download">Download diagnostics JSON</a>
        </section>
        <?php endif; ?>
      <?php endif; ?>
    </main>
    <?php if ($providerBranding['footer_visible']): ?>
    <footer class="orm-brand-footer" style="--orm-secondary: <?= htmlspecialchars($providerBranding['secondary_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; --orm-surface: <?= htmlspecialchars($providerBranding['surface_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; color: <?= htmlspecialchars($providerBranding['text_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; background: var(--orm-surface)">
      <span><?= htmlspecialchars($providerBranding['product_name'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></span>
      <?php if ($providerBranding['support_url'] !== ''): ?> · <a href="<?= htmlspecialchars($providerBranding['support_url'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">Support</a><?php endif; ?>
    </footer>
    <?php endif; ?>
    <?php
    print $cpanel->footer();
} finally {
    $cpanel->end();
}
