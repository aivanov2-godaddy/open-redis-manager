<?php
declare(strict_types=1);

require_once '/usr/local/cpanel/php/WHM.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmAcl.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Backend/BackendDiscovery.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Backend/BackendPolicyStore.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Backend/ProviderPolicyStore.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/SessionRequestGuard.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmAuditLog.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmAuditEventWriter.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmSecurityReport.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerClient.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Update/ReleasePreview.php';

$authenticatedUser = $_ENV['REMOTE_USER'] ?? getenv('REMOTE_USER');
$authenticatedUser = is_string($authenticatedUser) ? $authenticatedUser : null;
$authorized = \Orm\Security\WhmAcl::allowsAdministrativeAccess($authenticatedUser);
$rootAuthorized = $authorized && $authenticatedUser === 'root';
$report = $authorized ? (new \Orm\Backend\BackendDiscovery())->discover() : null;
$policyStore = new \Orm\Backend\BackendPolicyStore();
$policy = $rootAuthorized ? $policyStore->selectedBackend() : null;
$providerPolicyStore = new \Orm\Backend\ProviderPolicyStore();
$providerPolicy = $rootAuthorized ? $providerPolicyStore->load() : null;
$fleetOffset = filter_var($_GET['offset'] ?? 0, FILTER_VALIDATE_INT, ['options' => ['min_range' => 0, 'max_range' => 10000]]);
$fleetOffset = $fleetOffset === false ? 0 : $fleetOffset;
$fleetClient = new \Orm\Cpanel\BrokerClient();
$fleetPage = $rootAuthorized ? $fleetClient->requestFleetPage($fleetOffset) : null;
$fleetSummary = null;
$fleetSummaryMessage = null;
if ($rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'fleet.summary') {
    $fleetSummary = $fleetClient->requestFleetSummary();
    $fleetSummaryMessage = $fleetSummary === null
        ? ['type' => 'error', 'text' => 'The fleet summary could not be verified. Refresh the page and try again.']
        : ['type' => 'success', 'text' => 'Fleet summary loaded from verified account records and recent scheduled metric snapshots.'];
}
$updatePreview = null;
if ($rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'update.preview') {
    $updatePreview = \Orm\Update\ReleasePreview::run($authenticatedUser, $_SERVER);
}
$securityReport = null;
$securityReportMessage = null;
if ($rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'security.report') {
    $generatedAt = time();
    $rate = \Orm\Security\WhmSecurityReport::consumeRateLimit($generatedAt);
    if (!$rate['allowed']) {
        $securityReportMessage = ['type' => 'error', 'text' => 'Security reports are limited to one request per minute. Retry in ' . $rate['retry_after'] . ' seconds.'];
    } else {
        $securityFleet = $fleetClient->requestFleetSummary();
        $securityAudit = (new \Orm\Security\WhmAuditLog())->read(
            max(0, $generatedAt - 86400), $generatedAt
        );
        $securityReport = \Orm\Security\WhmSecurityReport::build($securityFleet, $securityAudit, $generatedAt);
        $auditLogged = \Orm\Security\WhmAuditEventWriter::securityReportGenerated();
        $securityReportMessage = [
            'type' => $securityFleet === null ? 'error' : 'success',
            'text' => $securityFleet === null
                ? 'The report is partial because verified fleet metrics were unavailable.'
                : 'A bounded report-only review was generated. No enforcement or automatic remediation was applied.',
        ];
        if (!$auditLogged) {
            $securityReport['partial'] = true;
            $securityReportMessage['text'] .= ' The report event could not be confirmed in the audit log.';
        }
    }
}
$resellerSummary = null;
$fleetDiagnosticsMessage = null;
$fleetDiagnosticsResult = null;
$fleetDiagnosticsRequest = $rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'fleet.diagnostics';
if ($fleetDiagnosticsRequest) {
    $username = $_POST['username'] ?? null;
    $result = is_string($username) ? $fleetClient->diagnoseFleetAccount($username) : null;
    if ($result === null) {
        $fleetDiagnosticsMessage = ['type' => 'error', 'text' => 'The diagnostic request could not be verified. Refresh the page and try again.'];
    } elseif ($result['success']) {
        $fleetDiagnosticsResult = $result;
        $fleetDiagnosticsMessage = [
            'type' => 'success',
            'text' => 'Read-only diagnostics completed for ' . $result['username'] . '.'
                . ($result['audit_logged'] ? ' The action was recorded in the system authentication log.'
                    : ' Warning: the result is available, but its audit record could not be confirmed.'),
        ];
    } else {
        $diagnosticMessages = [
            'account_unavailable' => 'The selected cPanel account could not be verified.',
            'not_configured' => 'The selected account does not have an ORM instance.',
            'not_running' => 'Start the selected cache before requesting diagnostics.',
            'rate_limited' => 'Wait a few seconds before requesting diagnostics for this account again.',
            'diagnostics_unavailable' => 'The fixed read-only probes could not produce a complete, validated result.',
        ];
        $fleetDiagnosticsMessage = [
            'type' => 'error',
            'text' => ($diagnosticMessages[$result['error'] ?? ''] ?? 'The diagnostic request was rejected.')
                . (array_key_exists('audit_logged', $result) && !$result['audit_logged']
                    ? ' The denial could not be confirmed in the audit log.' : ''),
        ];
    }
}
$fleetRecoveryMessage = null;
$fleetRecoveryResult = null;
$fleetRecoveryAction = $_POST['orm_action'] ?? null;
if ($rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && in_array($fleetRecoveryAction, ['fleet.recovery.scan', 'fleet.recovery.repair'], true)) {
    $username = $_POST['username'] ?? null;
    if (!is_string($username)) {
        $recovery = null;
    } elseif ($fleetRecoveryAction === 'fleet.recovery.scan') {
        $recovery = $fleetClient->scanFleetRecovery($username);
    } else {
        $repair = $_POST['repair'] ?? null;
        $recovery = is_string($repair) ? $fleetClient->repairFleetAccount($username, $repair) : null;
    }
    if ($recovery === null) {
        $fleetRecoveryMessage = ['type' => 'error', 'text' => 'The recovery request could not be verified. Refresh the page and try again.'];
    } elseif ($recovery['success'] && $fleetRecoveryAction === 'fleet.recovery.scan') {
        $fleetRecoveryResult = $recovery;
        $findingMessages = [
            'health_probe_failed' => 'The service reports running, but fixed health probes could not verify it. No automatic repair is available.',
            'not_configured' => 'The selected cPanel account does not have an ORM instance.',
            'service_failed' => 'The service is failed. ORM verified the instance manifest; the fixed Start service repair is available.',
            'service_healthy' => 'The service is running and passed the fixed read-only health probes.',
            'service_stopped' => 'The service is stopped. ORM verified the instance manifest; the fixed Start service repair is available.',
            'service_transitioning' => 'The service is changing state. Wait for it to settle, then scan again.',
        ];
        $fleetRecoveryMessage = [
            'type' => in_array($recovery['finding'], ['service_healthy', 'service_stopped', 'service_failed'], true) ? 'success' : 'error',
            'text' => 'Recovery scan for ' . $recovery['username'] . ': '
                . ($findingMessages[$recovery['finding']] ?? 'The scan returned an unknown finding.')
                . ($recovery['audit_logged'] ? ' The scan was recorded in the system authentication log.'
                    : ' Warning: the scan completed, but its audit record could not be confirmed.'),
        ];
    } elseif ($recovery['success']) {
        $fleetRecoveryMessage = [
            'type' => 'success',
            'text' => 'Start requested for ' . $recovery['username'] . '. Current state: ' . $recovery['state'] . '.'
                . ($recovery['audit_logged'] ? ' The repair was recorded in the system authentication log.'
                    : ' Warning: the service may have started, but its audit record could not be confirmed.'),
        ];
    } else {
        $recoveryErrors = [
            'account_unavailable' => 'The selected cPanel account could not be verified.',
            'instance_unavailable' => 'The instance manifest, ownership, or service state could not be verified; no repair was attempted.',
            'operation_in_progress' => 'Another operation is active for this account. Wait for it to finish, then scan again.',
            'rate_limited' => 'Wait before sending another recovery request for this account.',
            'repair_not_applicable' => 'The service is no longer verified as stopped or failed; scan it again before any repair.',
            'service_failed' => 'The fixed start operation failed. Scan the service again before retrying.',
        ];
        $fleetRecoveryMessage = [
            'type' => 'error',
            'text' => ($recoveryErrors[$recovery['error'] ?? ''] ?? 'The recovery request was rejected.')
                . (array_key_exists('audit_logged', $recovery) && !$recovery['audit_logged']
                    ? ' The result could not be confirmed in the audit log.' : ''),
        ];
    }
}
$fleetControlMessage = null;
$fleetBackupMessage = null;
$fleetBatchResult = null;
$fleetBatchMessage = null;
$fleetMigrationMessage = null;
$controlRequest = $rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'fleet.control';
if ($controlRequest) {
    $username = $_POST['username'] ?? null;
    $action = $_POST['fleet_action'] ?? null;
    $control = is_string($username) && is_string($action)
        ? $fleetClient->controlFleetAccount($username, $action)
        : null;
    if ($control === null) {
        $fleetControlMessage = ['type' => 'error', 'text' => 'The account action could not be verified. Refresh the page and try again.'];
    } elseif ($control['success']) {
        $fleetControlMessage = [
            'type' => 'success',
            'text' => ucfirst($control['action']) . ' requested for ' . $control['username'] . '. Current state: ' . $control['state'] . '.'
                . ($control['audit_logged'] ? ' The result was recorded in the system authentication log.'
                    : ' Warning: the service action may have completed, but its audit record could not be confirmed.'),
        ];
        if (is_array($fleetPage)) {
            foreach ($fleetPage['entries'] as &$entry) {
                if ($entry['username'] === $control['username']) {
                    $entry['state'] = $control['state'];
                }
            }
            unset($entry);
        }
    } else {
        $fleetMessages = [
            'account_unavailable' => 'The selected cPanel account could not be verified.',
            'instance_unavailable' => 'The selected cache instance could not be verified.',
            'not_configured' => 'The selected account does not have an ORM instance.',
            'rate_limited' => 'Wait a moment before sending another account action.',
            'service_failed' => 'The service action could not be completed. Check its status before trying again.',
        ];
        $fleetControlMessage = [
            'type' => 'error',
            'text' => ($fleetMessages[$control['error'] ?? ''] ?? 'The account action was rejected.')
                . (array_key_exists('audit_logged', $control) && !$control['audit_logged']
                    ? ' The denial could not be confirmed in the audit log.' : ''),
        ];
    }
}
$fleetBackupRequest = $rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'fleet.backup';
if ($fleetBackupRequest) {
    $username = $_POST['username'] ?? null;
    $action = $_POST['fleet_action'] ?? null;
    $backupId = $_POST['backup_id'] ?? null;
    $result = is_string($username) && is_string($action)
        ? $fleetClient->backupFleetAccount($username, $action, $action === 'restore' && is_string($backupId) ? $backupId : null)
        : null;
    if ($result === null) {
        $fleetBackupMessage = ['type' => 'error', 'text' => 'The account backup action could not be verified. Refresh the page and try again.'];
    } elseif ($result['success']) {
        if ($action === 'create' && is_array($result['backup'] ?? null) && is_array($fleetPage)) {
            foreach ($fleetPage['entries'] as &$entry) {
                if ($entry['username'] === $result['username']) {
                    $entry['backups'] = array_values(array_filter(
                        $entry['backups'],
                        static fn (array $backup): bool => $backup['id'] !== $result['backup']['id']
                    ));
                    array_unshift($entry['backups'], $result['backup']);
                    $entry['backups'] = array_slice($entry['backups'], 0, 3);
                    $entry['backups_available'] = true;
                }
            }
            unset($entry);
        }
        if ($action === 'create') {
            $text = 'Backup created for ' . $result['username'] . ': ' . $result['backup']['id'] . '.';
        } else {
            $text = 'Restored ' . $result['backup_id'] . ' for ' . $result['username']
                . '. Safety snapshot ' . $result['safety_backup_id'] . ' was retained; the cache is running.';
        }
        $fleetBackupMessage = [
            'type' => 'success',
            'text' => $text . ($result['audit_logged']
                ? ' The result was recorded in the system authentication log.'
                : ' Warning: the operation completed, but its audit record could not be confirmed.'),
        ];
    } else {
        $backupMessages = [
            'account_unavailable' => 'The selected cPanel account could not be verified.',
            'not_configured' => 'The selected account does not have an ORM instance.',
            'not_running' => 'Start the selected cache before creating or restoring a snapshot.',
            'rate_limited' => 'Wait a moment before repeating this account backup action.',
            'backup_not_found' => 'The selected snapshot is no longer retained for this account.',
            'backup_failed' => 'The snapshot could not be created.',
            'backup_invalid' => 'The snapshot did not pass validation and was not applied.',
            'backup_in_progress' => 'A backup or restore is already running for this account.',
            'backup_retention_failed' => 'The snapshot operation could not safely finish retention cleanup.',
            'backup_storage_unavailable' => 'Backup storage is unavailable or failed its security checks.',
            'restore_validation_unavailable' => 'The installed RDB validator is unavailable; no restore was applied.',
            'restore_failed' => 'The restore failed; ORM attempted to keep the cache available.',
            'restore_rollback_failed' => 'ORM could not verify its restore rollback. Check this account before retrying.',
        ];
        $operation = $action === 'restore' ? 'Restore' : 'Backup';
        $text = $operation . ' for ' . $result['username'] . ' was not completed. '
            . ($backupMessages[$result['error'] ?? ''] ?? 'The account action was rejected.');
        if (is_string($result['safety_backup_id'] ?? null)) {
            $text .= ' Safety snapshot ' . $result['safety_backup_id'] . ' was retained.';
        }
        if (array_key_exists('audit_logged', $result) && !$result['audit_logged']) {
            $text .= ' The denial could not be confirmed in the audit log.';
        }
        $fleetBackupMessage = ['type' => 'error', 'text' => $text];
    }
}
$fleetBatchRequest = $rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'fleet.backup.batch';
if ($fleetBatchRequest) {
    $action = $_POST['fleet_batch_action'] ?? null;
    $selected = $_POST['accounts'] ?? null;
    $targets = [];
    $entryByUsername = [];
    foreach (is_array($fleetPage['entries'] ?? null) ? $fleetPage['entries'] : [] as $entry) {
        $entryByUsername[$entry['username']] = $entry;
    }
    $validSelection = is_string($action) && in_array($action, ['create', 'restore'], true)
        && is_array($selected) && array_is_list($selected) && count($selected) >= 1 && count($selected) <= 2;
    if ($validSelection) {
        $seen = [];
        foreach ($selected as $username) {
            if (!is_string($username) || !isset($entryByUsername[$username]) || isset($seen[$username])
                || $entryByUsername[$username]['state'] !== 'running') {
                $validSelection = false;
                break;
            }
            $seen[$username] = true;
            if ($action === 'create') {
                $targets[] = ['username' => $username];
                continue;
            }
            $backupId = $_POST['backup_ids'][$username] ?? null;
            $ownedBackup = false;
            foreach ($entryByUsername[$username]['backups'] as $backup) {
                $ownedBackup = $ownedBackup || (is_string($backupId) && hash_equals($backup['id'], $backupId));
            }
            if (!$ownedBackup) {
                $validSelection = false;
                break;
            }
            $targets[] = ['username' => $username, 'backup_id' => $backupId];
        }
    }
    if (!$validSelection) {
        $fleetBatchMessage = ['type' => 'error', 'text' => 'Select one or two running accounts from this page and choose a retained snapshot for every restore target.'];
    } else {
        $fleetBatchResult = $fleetClient->backupFleetBatch($action, $targets);
        if ($fleetBatchResult === null) {
            $fleetBatchMessage = ['type' => 'error', 'text' => 'The batch result could not be verified. Check account status before retrying.'];
        } else {
            $outcomes = [];
            foreach ($fleetBatchResult['results'] as $item) {
                $outcomes[] = $item['success']
                    ? $item['username'] . ': ' . ($action === 'create' ? 'snapshot created' : 'snapshot restored with safety snapshot retained')
                    : $item['username'] . ': not completed (' . $item['error'] . ')';
            }
            $fleetBatchMessage = [
                'type' => $fleetBatchResult['partial'] ? 'error' : 'success',
                'text' => implode('; ', $outcomes) . ($fleetBatchResult['partial']
                    ? '. Some selected accounts failed; review each outcome before retrying.' : '.'),
            ];
        }
    }
}
$fleetMigrationRequest = $rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'fleet.migrate';
if ($fleetMigrationRequest) {
    $username = $_POST['username'] ?? null;
    $targetBackend = $_POST['target_backend'] ?? null;
    $writesQuiesced = ($_POST['writes_quiesced'] ?? null) === '1';
    $result = is_string($username) && is_string($targetBackend)
        ? $fleetClient->migrateFleetAccount($username, $targetBackend, $writesQuiesced)
        : null;
    if ($result === null) {
        $fleetMigrationMessage = ['type' => 'error', 'text' => 'The migration request could not be verified. Refresh the page and try again.'];
    } elseif ($result['success']) {
        if (is_array($fleetPage)) {
            foreach ($fleetPage['entries'] as &$entry) {
                if ($entry['username'] === $result['username']) {
                    $entry['backend'] = 'valkey';
                    $entry['state'] = 'running';
                }
            }
            unset($entry);
        }
        $fleetMigrationMessage = [
            'type' => 'success',
            'text' => 'Migrated ' . $result['username'] . ' to Valkey. Safety snapshot '
                . $result['safety_backup_id'] . ' was retained; the service is running.'
                . ($result['audit_logged'] ? ' The result was recorded in the system authentication log.'
                    : ' Warning: the migration completed, but its audit record could not be confirmed.'),
        ];
    } else {
        $migrationMessages = [
            'account_unavailable' => 'The selected cPanel account could not be verified.',
            'backend_unavailable' => 'Valkey is not installed or available on this server.',
            'backup_storage_unavailable' => 'Snapshot storage is unavailable or failed its security checks.',
            'migration_failed' => 'The switch did not complete; ORM restored Redis from the safety snapshot.',
            'migration_pause_failed' => 'ORM could not pause Redis writes; no migration was started.',
            'migration_recovery_required' => 'ORM could not verify automatic recovery. Keep application writers paused and inspect the account before retrying.',
            'migration_rollback_failed' => 'Automatic recovery failed. Keep application writers paused and inspect the retained snapshot before retrying.',
            'migration_state_unavailable' => 'ORM could not verify the source keyspace; no migration was started.',
            'migration_timeout' => 'The safety window expired; ORM cancelled the switch and resumed Redis.',
            'migration_unsupported' => 'This Redis/Valkey version combination is outside the supported migration range.',
            'migration_validation_failed' => 'The Valkey RDB validator rejected the safety snapshot; no switch was made.',
            'migration_validation_unavailable' => 'The Valkey RDB validator is unavailable; no switch was made.',
            'migration_snapshot_failed' => 'ORM could not create a safety snapshot; no switch was made.',
            'not_configured' => 'The selected account does not have an ORM instance.',
            'not_running' => 'Start the Redis instance before migrating it.',
            'operation_in_progress' => 'Another operation is already running for this account.',
            'rate_limited' => 'Wait before retrying this account migration.',
        ];
        $text = 'Migration for ' . ($result['username'] ?? $username) . ' was not completed. '
            . ($migrationMessages[$result['error'] ?? ''] ?? 'The account action was rejected.');
        if (is_string($result['safety_backup_id'] ?? null)) {
            $text .= ' Safety snapshot ' . $result['safety_backup_id'] . ' was retained.';
        }
        if (array_key_exists('audit_logged', $result) && !$result['audit_logged']) {
            $text .= ' The result could not be confirmed in the audit log.';
        }
        $fleetMigrationMessage = ['type' => 'error', 'text' => $text];
    }
}
$policyMessage = null;
if ($rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'backend.select') {
    $submittedBackend = $_POST['backend'] ?? null;
    $available = is_string($submittedBackend) && in_array($submittedBackend, ['redis', 'valkey'], true)
        ? array_filter($report['backends'] ?? [], static fn (array $backend): bool =>
            $backend['id'] === $submittedBackend && $backend['status'] === 'detected')
        : [];
    if ($available && $policyStore->select($submittedBackend)) {
        $policy = $submittedBackend;
        $policyMessage = 'The default backend for new ORM instances has been updated.';
        $auditLogged = \Orm\Security\WhmAuditEventWriter::backendSelection($submittedBackend, true);
        if (!$auditLogged) {
            $policyMessage .= ' Warning: the change succeeded, but its audit record could not be confirmed.';
        }
    } else {
        $policyMessage = 'The backend choice could not be saved. Choose an installed Redis-compatible backend.';
        \Orm\Security\WhmAuditEventWriter::backendSelection(
            is_string($submittedBackend) && in_array($submittedBackend, ['redis', 'valkey'], true) ? $submittedBackend : 'unavailable',
            false
        );
    }
}
$providerPolicyMessage = null;
if ($rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'provider.policy.update') {
    $providerAction = $_POST['provider_rule_action'] ?? null;
    $submittedMode = $_POST['provider_mode'] ?? null;
    $submittedExposure = $_POST['provider_exposure'] ?? ($providerPolicy['exposure'] ?? 'simple');
    $readPolicyInteger = static function (string $key, int $minimum, int $maximum): ?int {
        $raw = $_POST[$key] ?? null;
        if (!is_string($raw) || preg_match('/\A(?:0|[1-9][0-9]*)\z/', $raw) !== 1) {
            return null;
        }
        $value = filter_var($raw, FILTER_VALIDATE_INT);
        return is_int($value) && $value >= $minimum && $value <= $maximum ? $value : null;
    };
    $packageName = $_POST['package_name'] ?? '';
    $defaultMemory = $readPolicyInteger('default_memory_mib', 8, 64);
    $defaultRetention = $readPolicyInteger('default_backup_retention', 2, 3);
    if ($providerPolicy === null || !in_array($providerAction, [
        'default', 'save-package', 'remove-package', 'save-reseller', 'remove-reseller', 'save-branding',
    ], true)
        || !in_array($submittedMode, ['report-only', 'warn', 'enforce'], true)
        || ($providerAction === 'default' && !in_array($submittedExposure, ['simple', 'developer', 'advanced'], true))
        || $defaultMemory === null || $defaultRetention === null) {
        $providerPolicyMessage = 'The provider policy is unavailable or contains invalid values. No changes were saved.';
    } else {
        $updatedProviderPolicy = $providerPolicy;
        $updatedProviderPolicy['mode'] = $providerAction === 'default'
            ? $submittedMode : $providerPolicy['mode'];
        $updatedProviderPolicy['exposure'] = $providerAction === 'default'
            ? $submittedExposure : $providerPolicy['exposure'];
        $updatedProviderPolicy['default'] = [
            'enabled' => ($_POST['default_enabled'] ?? null) === '1',
            'max_memory_mib' => $defaultMemory,
            'backup_retention' => $defaultRetention,
        ];
        $validPackageName = is_string($packageName)
            && preg_match('/\A[a-zA-Z0-9_.-]{1,64}\z/', $packageName) === 1 && $packageName !== 'default';
        if ($providerAction === 'save-package') {
            $packageMemory = $readPolicyInteger('package_memory_mib', 8, 64);
            $packageRetention = $readPolicyInteger('package_backup_retention', 2, 3);
            if (!$validPackageName || $packageMemory === null || $packageRetention === null) {
                $providerPolicyMessage = 'Enter a valid package name, memory ceiling, and backup retention. No changes were saved.';
            } else {
                $updatedProviderPolicy['packages'][$packageName] = [
                    'enabled' => ($_POST['package_enabled'] ?? null) === '1',
                    'max_memory_mib' => $packageMemory,
                    'backup_retention' => $packageRetention,
                ];
            }
        } elseif ($providerAction === 'remove-package') {
            if (!$validPackageName || !array_key_exists($packageName, $updatedProviderPolicy['packages'])) {
                $providerPolicyMessage = 'The requested package rule was not found. No changes were saved.';
            } else {
                unset($updatedProviderPolicy['packages'][$packageName]);
            }
        } elseif ($providerAction === 'save-reseller') {
            $resellerOwner = $_POST['reseller_owner'] ?? null;
            $maxInstances = $readPolicyInteger('reseller_max_instances', 0, 100000);
            $maxMemory = $readPolicyInteger('reseller_max_memory_mib', 0, 1000000);
            if (!is_string($resellerOwner) || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $resellerOwner) !== 1
                || $maxInstances === null || $maxMemory === null) {
                $providerPolicyMessage = 'Enter a valid trusted OWNER name and non-negative quota values. No changes were saved.';
            } else {
                $updatedProviderPolicy['resellers'][$resellerOwner] = [
                    'max_instances' => $maxInstances,
                    'max_memory_mib' => $maxMemory,
                ];
            }
        } elseif ($providerAction === 'remove-reseller') {
            $resellerOwner = $_POST['reseller_owner'] ?? null;
            if (!is_string($resellerOwner) || !array_key_exists($resellerOwner, $updatedProviderPolicy['resellers'])) {
                $providerPolicyMessage = 'The requested reseller rule was not found. No changes were saved.';
            } else {
                unset($updatedProviderPolicy['resellers'][$resellerOwner]);
            }
        } elseif ($providerAction === 'save-branding') {
            $logoUpload = $_FILES['branding_logo'] ?? null;
            $logoUploadError = is_array($logoUpload) ? ($logoUpload['error'] ?? UPLOAD_ERR_NO_FILE) : UPLOAD_ERR_NO_FILE;
            $clearLogo = ($_POST['branding_clear_logo'] ?? null) === '1';
            $branding = $providerPolicy['branding'];
            $branding['product_name'] = $_POST['branding_product_name'] ?? null;
            $branding['support_url'] = $_POST['branding_support_url'] ?? null;
            $branding['preset'] = $_POST['branding_preset'] ?? null;
            $branding['primary_color'] = $_POST['branding_primary_color'] ?? null;
            $branding['secondary_color'] = $_POST['branding_secondary_color'] ?? null;
            $branding['surface_color'] = $_POST['branding_surface_color'] ?? null;
            $branding['text_color'] = $_POST['branding_text_color'] ?? null;
            $branding['footer_visible'] = ($_POST['branding_footer_visible'] ?? null) === '1';
            if ($clearLogo && $logoUploadError !== UPLOAD_ERR_NO_FILE) {
                $providerPolicyMessage = 'Choose either a new logo or remove the current logo, not both. No changes were saved.';
            } elseif ($clearLogo) {
                $branding['logo_png_base64'] = '';
            } elseif ($logoUploadError !== UPLOAD_ERR_NO_FILE) {
                $temporaryPath = is_array($logoUpload) && is_string($logoUpload['tmp_name'] ?? null)
                    ? $logoUpload['tmp_name'] : '';
                $uploadedSize = is_array($logoUpload) ? ($logoUpload['size'] ?? null) : null;
                if ($logoUploadError !== UPLOAD_ERR_OK || !is_int($uploadedSize) || $uploadedSize < 1 || $uploadedSize > 32768
                    || $temporaryPath === '' || !is_uploaded_file($temporaryPath)) {
                    $providerPolicyMessage = 'The logo upload must be a PNG no larger than 32 KiB. No changes were saved.';
                } else {
                    $logoBytes = @file_get_contents($temporaryPath);
                    if (!is_string($logoBytes) || strlen($logoBytes) !== $uploadedSize || strlen($logoBytes) > 32768) {
                        $providerPolicyMessage = 'The logo upload could not be read safely. No changes were saved.';
                    } else {
                        $branding['logo_png_base64'] = base64_encode($logoBytes);
                    }
                }
            }
            if ($providerPolicyMessage === null) {
                $normalizedBranding = \Orm\Backend\ProviderPolicyStore::normalizeBranding($branding);
                if ($normalizedBranding === null) {
                    $providerPolicyMessage = 'Check the product name, HTTPS support URL, PNG dimensions, and color contrast. No changes were saved.';
                } else {
                    $updatedProviderPolicy['branding'] = $normalizedBranding;
                }
            }
        }

        if ($providerPolicyMessage === null) {
            if ($providerPolicyStore->save($updatedProviderPolicy)) {
                $providerPolicy = $providerPolicyStore->load();
                $providerPolicyMessage = $providerPolicy === null
                    ? 'The policy was written, but could not be re-read safely. Check the root-owned policy file.'
                    : ($providerAction === 'save-branding'
                        ? 'Provider branding saved and mirrored to cPanel.'
                        : 'Provider policy saved. Reseller quotas gate new provisions only; existing instances were not rewritten.');
                if (!\Orm\Security\WhmAuditEventWriter::providerPolicyChanged($providerAction)) {
                    $providerPolicyMessage .= ' Warning: the change succeeded, but its audit record could not be confirmed.';
                }
            } else {
                $providerPolicyMessage = 'The provider policy could not be saved safely. No changes were applied.';
            }
        }
    }
}
$fleetPageStateCounts = array_fill_keys(['failed', 'running', 'starting', 'stopped', 'stopping', 'unhealthy'], 0);
if (is_array($fleetPage)) {
    foreach ($fleetPage['entries'] as $fleetEntry) {
        if (isset($fleetPageStateCounts[$fleetEntry['state']])) {
            ++$fleetPageStateCounts[$fleetEntry['state']];
        }
    }
}
$resellerSummary = $rootAuthorized ? $fleetClient->request('provider.resellers') : null;
$auditToday = gmdate('Y-m-d');
$auditYesterday = gmdate('Y-m-d', time() - 86400);
$auditForm = [
    'from' => is_string($_POST['audit_from'] ?? null) ? $_POST['audit_from'] : $auditYesterday,
    'to' => is_string($_POST['audit_to'] ?? null) ? $_POST['audit_to'] : $auditToday,
    'account' => is_string($_POST['audit_account'] ?? null) ? $_POST['audit_account'] : '',
    'action' => is_string($_POST['audit_action'] ?? null) ? $_POST['audit_action'] : '',
    'result' => is_string($_POST['audit_result'] ?? null) ? $_POST['audit_result'] : '',
];
$auditResult = null;
$auditMessage = null;
$auditPage = filter_var($_POST['audit_page'] ?? 0, FILTER_VALIDATE_INT, ['options' => ['min_range' => 0, 'max_range' => 19]]);
$auditPage = $auditPage === false ? 0 : $auditPage;
$auditRequest = $rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && in_array($_POST['orm_audit_action'] ?? null, ['search', 'export'], true);
if ($auditRequest) {
    $datesMatchShape = preg_match('/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/', $auditForm['from']) === 1
        && preg_match('/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/', $auditForm['to']) === 1;
    $fromDate = $datesMatchShape ? DateTimeImmutable::createFromFormat('!Y-m-d', $auditForm['from'], new DateTimeZone('UTC')) : false;
    $toDate = $datesMatchShape ? DateTimeImmutable::createFromFormat('!Y-m-d', $auditForm['to'], new DateTimeZone('UTC')) : false;
    $datesValid = $fromDate instanceof DateTimeImmutable && $toDate instanceof DateTimeImmutable
        && $fromDate->format('Y-m-d') === $auditForm['from'] && $toDate->format('Y-m-d') === $auditForm['to'];
    $auditFilters = \Orm\Security\WhmAuditLog::normalizeFilters([
        'account' => $auditForm['account'], 'action' => $auditForm['action'], 'result' => $auditForm['result'],
    ]);
    if (!$datesValid || $auditFilters === null
        || $toDate->getTimestamp() + 86399 < $fromDate->getTimestamp()
        || $toDate->getTimestamp() + 86399 - $fromDate->getTimestamp() >= 604800) {
        $auditMessage = 'Choose valid filters and a UTC date range no longer than seven days.';
    } else {
        $auditResult = (new \Orm\Security\WhmAuditLog())->read(
            $fromDate->getTimestamp(), $toDate->getTimestamp() + 86399, $auditFilters
        );
        if (($auditResult['success'] ?? false) !== true) {
            $auditMessage = 'The audit query could not be completed. Check the filters and try again.';
        } elseif ($_POST['orm_audit_action'] === 'export') {
            $json = \Orm\Security\WhmAuditLog::toJson($auditResult);
            if ($json === null) {
                http_response_code(500);
                exit;
            }
            header('Content-Type: application/json; charset=utf-8');
            header('Cache-Control: private, no-store, max-age=0');
            header('X-Content-Type-Options: nosniff');
            header('Content-Disposition: attachment; filename="orm-audit-' . gmdate('Ymd-His') . '.json"');
            echo $json;
            exit;
        }
    }
}

if (!$authorized) {
    http_response_code(403);
}

WHM::header('Open Redis Manager', 0, 0);
?>
<style>.orm-entry h1{display:flex;align-items:center;gap:10px}.orm-fleet-batch-controls{display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding:12px 0}.orm-fleet-batch-controls p{flex-basis:100%;margin:0}.orm-visually-hidden{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}</style>
<main class="orm-entry" aria-labelledby="orm-title">
  <h1 id="orm-title"><svg width="34" height="34" viewBox="0 0 256 256" aria-hidden="true"><title>Open Redis Manager cache cube</title>
  <rect x="4" y="4" width="248" height="248" rx="58" fill="#D92D20"/><rect x="5" y="5" width="246" height="246" rx="57" fill="none" stroke="#FFF" stroke-opacity=".18" stroke-width="2"/>
  <path d="m128 47 67 37-67 37-67-37 67-37Z" fill="#FFF"/><path d="m61 84 67 37v67l-67-37V84Z" fill="#FFE5E1"/><path d="m128 121 67-37v67l-67 37v-67Z" fill="#FFF"/><path d="m128 63 39 21-39 22-39-22 39-21Z" fill="#D92D20"/><path d="m128 72 23 12-23 13-23-13 23-12Z" fill="#F9BDB6"/><path d="m68 128 60 32 60-32M68 140l60 32 60-32" fill="none" stroke="#D92D20" stroke-linecap="round" stroke-linejoin="round" stroke-width="8"/>
</svg>Open Redis Manager</h1>
  <?php if (!$authorized): ?>
    <p role="alert">Access denied. This page requires root-level WHM access.</p>
  <?php elseif ($report['status'] !== 'supported-platform'): ?>
    <p role="status">Backend discovery is unavailable on this platform.</p>
  <?php else: ?>
    <p>Live backend discovery from the authenticated WHM session.</p>
    <?php if ($rootAuthorized): ?>
    <section aria-labelledby="orm-update-preview-title">
      <h2 id="orm-update-preview-title">Signed update preview</h2>
      <p>Verify a root-staged ORM release and review its signed version, trusted key, artifact digest, and managed file changes. This preview does not apply the update.</p>
      <?php if ($updatePreview !== null): ?>
        <?php if (($updatePreview['ok'] ?? false) !== true): ?>
          <p role="alert"><?= htmlspecialchars((string) ($updatePreview['message'] ?? 'The update preview could not be verified.'), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
        <?php else: ?>
          <p role="status">Signature and compatibility verified. No files were changed.</p>
          <dl>
            <dt>Installed version</dt><dd><?= htmlspecialchars($updatePreview['installedVersion'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></dd>
            <dt>Candidate version</dt><dd><?= htmlspecialchars($updatePreview['candidateVersion'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></dd>
            <dt>Release channel</dt><dd><?= htmlspecialchars($updatePreview['release']['channel'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></dd>
            <dt>Trusted key ID</dt><dd><?= htmlspecialchars($updatePreview['release']['keyId'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></dd>
            <dt>Artifact SHA-256</dt><dd><code><?= htmlspecialchars($updatePreview['release']['artifactSha256'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></dd>
          </dl>
          <ul aria-label="Update file change summary">
            <?php foreach (['add' => 'Add', 'replace' => 'Replace', 'unchanged' => 'Unchanged', 'move' => 'Move', 'conflict' => 'Conflict', 'retire' => 'Retire'] as $action => $label): ?>
              <li><?= htmlspecialchars($label, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>: <?= (int) $updatePreview['summary'][$action] ?></li>
            <?php endforeach; ?>
          </ul>
          <details>
            <summary>Review managed file actions</summary>
            <table>
              <thead><tr><th scope="col">File key</th><th scope="col">Action</th><th scope="col">Target</th><th scope="col">Review</th></tr></thead>
              <tbody>
                <?php foreach ($updatePreview['fileActions'] as $fileAction): ?>
                  <tr>
                    <th scope="row"><?= htmlspecialchars($fileAction['key'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></th>
                    <td><?= htmlspecialchars(ucfirst($fileAction['action']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
                    <td><code><?= htmlspecialchars($fileAction['target'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></td>
                    <td><?= $fileAction['requiresReview'] ? 'Required' : 'No' ?></td>
                  </tr>
                <?php endforeach; ?>
              </tbody>
            </table>
          </details>
        <?php endif; ?>
      <?php endif; ?>
      <form method="post">
        <input type="hidden" name="orm_action" value="update.preview">
        <button type="submit">Verify staged release</button>
      </form>
      <p>The preview reads fixed root-owned paths: <code>/var/cpanel/orm/updates/staged/</code> and <code>/etc/orm/release-keys/</code>. Releases are not downloaded automatically, and this control cannot install one.</p>
    </section>
    <section aria-labelledby="orm-fleet-title">
      <h2 id="orm-fleet-title">Managed ORM instances</h2>
      <?php if ($fleetControlMessage !== null): ?>
        <p role="<?= $fleetControlMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($fleetControlMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
      <?php endif; ?>
      <?php if ($fleetBackupMessage !== null): ?>
        <p role="<?= $fleetBackupMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($fleetBackupMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
      <?php endif; ?>
      <?php if ($fleetMigrationMessage !== null): ?>
        <p role="<?= $fleetMigrationMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($fleetMigrationMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
      <?php endif; ?>
      <?php if ($fleetDiagnosticsMessage !== null): ?>
        <p role="<?= $fleetDiagnosticsMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($fleetDiagnosticsMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
      <?php endif; ?>
      <?php if ($fleetRecoveryMessage !== null): ?>
        <p role="<?= $fleetRecoveryMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($fleetRecoveryMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
      <?php endif; ?>
      <?php if ($fleetDiagnosticsResult !== null): ?>
        <?php $diagnosticLabels = [
            'backend' => 'Backend', 'server_version' => 'Server version', 'uptime_seconds' => 'Uptime (seconds)',
            'memory_used_bytes' => 'Memory used (bytes)', 'memory_peak_bytes' => 'Memory peak (bytes)',
            'maxmemory_bytes' => 'Configured memory limit (bytes)', 'connected_clients' => 'Connected clients',
            'blocked_clients' => 'Blocked clients', 'maxclients' => 'Client limit', 'commands_per_second' => 'Commands per second',
            'database_keys' => 'Keys in database 0', 'keyspace_hits' => 'Keyspace hits',
            'keyspace_misses' => 'Keyspace misses', 'expired_keys' => 'Expired keys', 'evicted_keys' => 'Evicted keys',
        ]; ?>
        <h3>Read-only diagnostics for <code><?= htmlspecialchars($fleetDiagnosticsResult['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></h3>
        <table><tbody>
          <?php foreach ($diagnosticLabels as $field => $label): ?>
            <tr><th scope="row"><?= htmlspecialchars($label, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></th>
              <td><?= htmlspecialchars(is_int($fleetDiagnosticsResult['diagnostics'][$field])
                    ? number_format($fleetDiagnosticsResult['diagnostics'][$field])
                    : (string) $fleetDiagnosticsResult['diagnostics'][$field], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td></tr>
          <?php endforeach; ?>
        </tbody></table>
        <p>Only fixed, read-only Redis/Valkey probes are used. This report contains counters and configuration metrics; it does not return keys, values, credentials, or raw command output.</p>
      <?php endif; ?>
      <?php if ($fleetPage === null): ?>
        <p role="status">The managed-instance inventory is unavailable. Backend discovery and existing services are unchanged.</p>
      <?php else: ?>
        <?php $fleetPageCount = count($fleetPage['entries']); $fleetFirstAccount = $fleetPageCount > 0 ? $fleetOffset + 1 : 0; $fleetLastAccount = $fleetOffset + $fleetPageCount; ?>
        <p><strong><?= htmlspecialchars((string) $fleetPage['total'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong> verified configured ORM accounts in the full inventory. Showing <?= $fleetPageCount > 0 ? $fleetFirstAccount . '–' . $fleetLastAccount : 'no accounts' ?> of <?= htmlspecialchars((string) $fleetPage['total'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>.</p>
        <p>State counts for this page only (<?= $fleetPageCount ?> accounts): running <?= $fleetPageStateCounts['running'] ?>, stopped <?= $fleetPageStateCounts['stopped'] ?>, starting <?= $fleetPageStateCounts['starting'] ?>, stopping <?= $fleetPageStateCounts['stopping'] ?>, failed <?= $fleetPageStateCounts['failed'] ?>, unverifiable <?= $fleetPageStateCounts['unhealthy'] ?>. “Unverifiable” means ORM could not confirm the manifest, ownership, or service state.</p>
        <?php if ($fleetSummaryMessage !== null): ?><p role="<?= $fleetSummaryMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($fleetSummaryMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p><?php endif; ?>
        <form method="post" class="orm-fleet-actions">
          <input type="hidden" name="orm_action" value="fleet.summary">
          <button type="submit"><svg aria-hidden="true" viewBox="0 0 20 20" width="14" height="14"><path d="M3 16V9m5 7V4m5 12v-5m4 5V7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg> Load fleet summary</button>
        </form>
        <?php if ($fleetSummary !== null): ?>
          <?php $fleetMetrics = $fleetSummary['metrics']; $fleetStates = $fleetSummary['state_counts']; ?>
          <section aria-labelledby="orm-fleet-summary-title">
            <h3 id="orm-fleet-summary-title">Verified fleet summary<?= $fleetSummary['partial'] ? ' · partial data' : '' ?></h3>
            <p><?= (int) $fleetSummary['managed_count'] ?> managed, <?= (int) $fleetStates['running'] ?> running, <?= (int) $fleetSummary['unconfigured_count'] ?> unconfigured, <?= (int) $fleetSummary['unverified_count'] ?> unverified. States are read from one bounded systemd query; metrics use scheduled snapshots no older than 15 minutes.</p>
            <p>Fresh metrics for <?= (int) $fleetMetrics['fresh_accounts'] ?> accounts: <?= number_format($fleetMetrics['memory_used_bytes']) ?> bytes used across <?= number_format($fleetMetrics['connected_clients']) ?> connected clients. Alerts: <?= (int) $fleetMetrics['alert_accounts'] ?> accounts (<?= (int) $fleetMetrics['high_memory_accounts'] ?> memory, <?= (int) $fleetMetrics['high_client_accounts'] ?> clients, <?= (int) $fleetMetrics['low_hit_ratio_accounts'] ?> hit ratio). Stale <?= (int) $fleetMetrics['stale_accounts'] ?>; missing <?= (int) $fleetMetrics['missing_accounts'] ?>. Missing and stale values are excluded from totals, never treated as zero.</p>
            <?php if (($fleetMetrics['rate_accounts'] ?? 0) > 0): ?><p>Counter-rate samples: <?= (int) $fleetMetrics['rate_accounts'] ?> measured, <?= (int) $fleetMetrics['rate_missing_accounts'] ?> unknown. <?= (int) $fleetMetrics['eviction_activity_accounts'] ?> accounts recorded evictions; maximum per-account delta <?= number_format($fleetMetrics['max_evictions_per_window']) ?>. Maximum average operations rate <?= number_format($fleetMetrics['max_operations_per_second']) ?> per second. Actual windows range <?= (int) $fleetMetrics['rate_window_min_seconds'] ?>–<?= (int) $fleetMetrics['rate_window_max_seconds'] ?> seconds and span <?= gmdate('Y-m-d\TH:i:s\Z', $fleetMetrics['rate_window_earliest_start_at']) ?> through <?= gmdate('Y-m-d\TH:i:s\Z', $fleetMetrics['rate_window_latest_end_at']) ?> UTC; intervals over 26 hours, resets, and missing baselines are unknown.</p><?php else: ?><p>Counter-rate samples are not yet available. They require two compatible samples; resets, missing baselines, and gaps over 26 hours remain unknown.</p><?php endif; ?>
            <?php if (($fleetMetrics['auth_rate_accounts'] ?? 0) > 0): ?><p>Authentication-failure counters: <?= (int) $fleetMetrics['auth_rate_accounts'] ?> measured, <?= (int) $fleetMetrics['auth_rate_missing_accounts'] ?> unknown. <?= (int) $fleetMetrics['auth_failure_accounts'] ?> accounts recorded failures; the largest per-account delta was <?= number_format($fleetMetrics['max_auth_failures_per_window']) ?>. These anonymous backend counters do not identify clients or establish abuse. Sample windows range <?= (int) $fleetMetrics['auth_rate_window_min_seconds'] ?>–<?= (int) $fleetMetrics['auth_rate_window_max_seconds'] ?> seconds.</p><?php else: ?><p>Authentication-failure counters are not yet available for a bounded sample window. Older backends may not expose this optional INFO field; missing fields, resets, and missing baselines are unknown.</p><?php endif; ?>
          </section>
        <?php endif; ?>
        <section aria-labelledby="orm-security-report-title">
          <h3 id="orm-security-report-title">Security and abuse review</h3>
          <p>This report is read-only and report-only. It uses fresh fleet metrics, verified counter deltas from bounded sample windows, and normalized ORM AUTH management events. Where supported, backend authentication-failure counters are anonymous and aggregate; they do not identify clients or distinguish mistakes from attacks. Missing fields and resets remain unknown. Rates are descriptive signals without an abuse threshold; the report does not inspect passwords or Redis keys and does not enforce or remediate.</p>
          <?php if ($securityReportMessage !== null): ?><p role="<?= $securityReportMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($securityReportMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p><?php endif; ?>
          <form method="post">
            <input type="hidden" name="orm_action" value="security.report">
            <button type="submit"><svg aria-hidden="true" viewBox="0 0 20 20" width="14" height="14"><path d="M10 2.5 17 5v4.5c0 4-2.7 6.8-7 8-4.3-1.2-7-4-7-8V5zM7 10l2 2 4-4" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg> Generate report-only review</button>
          </form>
          <?php if (is_array($securityReport)): ?>
            <p role="status">Generated <?= htmlspecialchars($securityReport['generated_at_utc'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?><?= $securityReport['partial'] ? ' · partial evidence' : '' ?>. Metric freshness window: 15 minutes. Counter-rate windows: up to 26 hours, based on actual sample times. AUTH management event window: 24 hours.</p>
            <?php if ($securityReport['findings'] === []): ?><p>No current reportable findings were observed in the available inputs.</p><?php endif; ?>
            <?php if ($securityReport['findings'] !== []): ?>
              <ul>
                <?php foreach ($securityReport['findings'] as $finding): ?>
                  <li><strong><?= htmlspecialchars(ucwords(str_replace('_', ' ', $finding['category'])), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong> (<?= htmlspecialchars($finding['severity'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>): <?= $finding['count'] === null ? 'unknown count' : (int) $finding['count'] . ' account/event(s)' ?>. <?= htmlspecialchars($finding['evidence'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> <?= htmlspecialchars($finding['recommendation'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?><?= is_string($finding['sampled_at_utc']) ? ' Sampled at ' . htmlspecialchars($finding['sampled_at_utc'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') . '.' : '' ?></li>
                <?php endforeach; ?>
              </ul>
            <?php endif; ?>
            <details><summary>Signals not evaluated</summary><ul><?php foreach ($securityReport['unmeasured'] as $signal => $reason): ?><li><?= htmlspecialchars(ucwords(str_replace('_', ' ', $signal)), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>: <?= htmlspecialchars($reason, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></li><?php endforeach; ?></ul></details>
          <?php endif; ?>
        </section>
        <?php if ($fleetPage['total'] > 0): ?>
        <label for="orm-fleet-search">Search this page</label>
        <input id="orm-fleet-search" type="search" autocomplete="off">
        <label for="orm-fleet-state">Filter by state</label>
        <select id="orm-fleet-state">
          <option value="">All states</option>
          <option value="running">Running</option>
          <option value="starting">Starting</option>
          <option value="stopping">Stopping</option>
          <option value="stopped">Stopped</option>
          <option value="failed">Failed</option>
          <option value="unhealthy">Unverifiable</option>
        </select>
        <p>Each row shows snapshots retained for that account. Migration is available for running Redis instances only. Stop all application writers before using it; service connections will be interrupted while the snapshot is validated and the backend is switched.</p>
        <?php if ($fleetBatchMessage !== null): ?><p role="<?= $fleetBatchMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($fleetBatchMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p><?php endif; ?>
        <div class="orm-fleet-batch-controls">
          <form method="post" id="orm-fleet-batch-create">
            <input type="hidden" name="orm_action" value="fleet.backup.batch">
            <input type="hidden" name="fleet_batch_action" value="create">
            <button type="submit" onclick="return confirm('Create snapshots for the selected running accounts? Select no more than two accounts. Each account is processed separately, so one failure will not stop the other.')"><svg aria-hidden="true" viewBox="0 0 20 20" width="14" height="14"><path d="M10 3v14M3 10h14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg> Create snapshots for selected accounts</button>
          </form>
          <form method="post" id="orm-fleet-batch-restore">
            <input type="hidden" name="orm_action" value="fleet.backup.batch">
            <input type="hidden" name="fleet_batch_action" value="restore">
            <button type="submit" onclick="return confirm('Restore snapshots for the selected running accounts? Newer writes may be lost. ORM creates a per-account safety snapshot and uses rollback if restore fails. Select no more than two accounts.')"><svg aria-hidden="true" viewBox="0 0 20 20" width="14" height="14"><path d="M4 8a6.5 6.5 0 1 1-.3 4M4 3v5h5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg> Restore selected snapshots</button>
          </form>
          <p>Batch operations apply only to this visible page and at most two running accounts per request. Each outcome is reported independently and recorded in the system authentication log.</p>
        </div>
        <table>
           <thead><tr><th scope="col">cPanel account</th><th scope="col">Backend</th><th scope="col">Instance state</th><th scope="col">Service actions</th><th scope="col">Read-only diagnostics</th><th scope="col">Recovery scan</th><th scope="col">Migration</th><th scope="col">Backups and restore</th></tr></thead>
          <tbody id="orm-fleet-rows">
            <?php foreach ($fleetPage['entries'] as $entry): ?>
              <tr data-account="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" data-state="<?= htmlspecialchars($entry['state'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                <th scope="row"><label><input type="checkbox" name="accounts[]" value="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" form="orm-fleet-batch-create"<?= $entry['state'] === 'running' ? '' : ' disabled' ?>> <?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> <span class="orm-visually-hidden">for batch snapshot</span></label><br><label><input type="checkbox" name="accounts[]" value="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" form="orm-fleet-batch-restore"<?= $entry['state'] === 'running' && $entry['backups_available'] && $entry['backups'] !== [] ? '' : ' disabled' ?>> Select for batch restore</label></th>
                <td><?= htmlspecialchars(ucfirst($entry['backend']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
                <td><?= htmlspecialchars($entry['state'] === 'unhealthy' ? 'Unverifiable' : ucfirst($entry['state']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
                <td>
                  <form method="post" class="orm-fleet-actions">
                    <input type="hidden" name="orm_action" value="fleet.control">
                    <input type="hidden" name="username" value="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                    <button type="submit" name="fleet_action" value="start"><svg aria-hidden="true" viewBox="0 0 20 20" width="14" height="14"><path d="M5 3.5v13l11-6.5z" fill="currentColor"/></svg> Start</button>
                    <button type="submit" name="fleet_action" value="stop" onclick="return confirm('Stop the cache for <?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>? Connected applications may fail until it is started again.')"><svg aria-hidden="true" viewBox="0 0 20 20" width="14" height="14"><rect x="4.5" y="4.5" width="11" height="11" rx="1" fill="currentColor"/></svg> Stop</button>
                    <button type="submit" name="fleet_action" value="restart" onclick="return confirm('Restart the cache for <?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>? Connected applications may briefly lose access.')"><svg aria-hidden="true" viewBox="0 0 20 20" width="14" height="14"><path d="M15.7 7.5A6 6 0 0 0 5.3 5.7L3.5 7.5M3.5 4v3.5H7M4.3 12.5a6 6 0 0 0 10.4 1.8l1.8-1.8m0 3.5v-3.5H13" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg> Restart</button>
                  </form>
                </td>
                <td>
                  <form method="post" class="orm-fleet-actions">
                    <input type="hidden" name="orm_action" value="fleet.diagnostics">
                    <input type="hidden" name="username" value="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                    <button type="submit"<?= $entry['state'] === 'running' ? '' : ' disabled' ?>>Run diagnostics</button>
                  </form>
                </td>
                <td>
                  <form method="post" class="orm-fleet-actions">
                    <input type="hidden" name="orm_action" value="fleet.recovery.scan">
                    <input type="hidden" name="username" value="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                    <button type="submit">Read-only scan</button>
                  </form>
                  <?php if ($fleetRecoveryResult !== null && $fleetRecoveryResult['username'] === $entry['username'] && ($fleetRecoveryResult['repair'] ?? null) === 'start'): ?>
                    <form method="post" class="orm-fleet-actions">
                      <input type="hidden" name="orm_action" value="fleet.recovery.repair">
                      <input type="hidden" name="username" value="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                      <input type="hidden" name="repair" value="start">
                      <button type="submit" onclick="return confirm('Start the verified stopped or failed ORM service for <?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>?')">Start service</button>
                    </form>
                  <?php endif; ?>
                </td>
                <td>
                  <?php if ($entry['backend'] === 'redis'): ?>
                    <form method="post" class="orm-fleet-actions">
                      <input type="hidden" name="orm_action" value="fleet.migrate">
                      <input type="hidden" name="username" value="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                      <input type="hidden" name="target_backend" value="valkey">
                      <label><input type="checkbox" name="writes_quiesced" value="1" required> Application writers are stopped or paused</label>
                      <button type="submit"<?= $entry['state'] === 'running' ? '' : ' disabled' ?> onclick="return confirm('Migrate <?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> from Redis to Valkey? The cache will be interrupted. ORM will save and validate a safety snapshot, and will attempt to roll back automatically if the switch fails.')">Migrate to Valkey</button>
                    </form>
                  <?php else: ?>
                    <span><?= $entry['backend'] === 'valkey' ? 'Already using Valkey' : 'Unavailable' ?></span>
                  <?php endif; ?>
                </td>
                <td>
                  <form method="post" class="orm-fleet-actions">
                    <input type="hidden" name="orm_action" value="fleet.backup">
                    <input type="hidden" name="username" value="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                    <button type="submit" name="fleet_action" value="create"<?= $entry['state'] === 'running' ? '' : ' disabled' ?>>Create snapshot</button>
                  </form>
                  <?php if (!$entry['backups_available']): ?>
                    <p>Snapshot list unavailable.</p>
                  <?php elseif ($entry['backups'] === []): ?>
                    <p>No retained snapshots for this account.</p>
                  <?php else: ?>
                    <form method="post" class="orm-fleet-actions">
                      <input type="hidden" name="orm_action" value="fleet.backup">
                      <input type="hidden" name="fleet_action" value="restore">
                      <input type="hidden" name="username" value="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                      <label for="orm-backup-<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">Snapshot</label>
                      <select id="orm-backup-<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" name="backup_id" required>
                        <?php foreach ($entry['backups'] as $backup): ?>
                          <option value="<?= htmlspecialchars($backup['id'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>"><?= htmlspecialchars(gmdate('Y-m-d H:i:s', $backup['created_at']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> UTC · <?= number_format($backup['size_bytes']) ?> bytes</option>
                        <?php endforeach; ?>
                      </select>
                      <label for="orm-batch-backup-<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">Batch restore snapshot</label>
                      <select id="orm-batch-backup-<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" name="backup_ids[<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>]" form="orm-fleet-batch-restore">
                        <?php foreach ($entry['backups'] as $backup): ?>
                          <option value="<?= htmlspecialchars($backup['id'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>"><?= htmlspecialchars(gmdate('Y-m-d H:i:s', $backup['created_at']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> UTC</option>
                        <?php endforeach; ?>
                      </select>
                      <button type="submit"<?= $entry['state'] === 'running' ? '' : ' disabled' ?> onclick="return confirm('Restore this snapshot for <?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>? The cache will stop briefly, writes newer than the snapshot may be lost, and ORM will create a safety snapshot first.')">Restore snapshot</button>
                    </form>
                  <?php endif; ?>
                </td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
        <nav aria-label="Managed account pages">
          <?php if ($fleetOffset > 0): ?><a href="?offset=<?= max(0, $fleetOffset - 4) ?>">Previous page</a><?php endif; ?>
          <?php if ($fleetOffset + count($fleetPage['entries']) < $fleetPage['total']): ?><a href="?offset=<?= $fleetOffset + 4 ?>">Next page</a><?php endif; ?>
        </nav>
        <script>
          (() => {
            const search = document.getElementById('orm-fleet-search');
            const state = document.getElementById('orm-fleet-state');
            const rows = [...document.querySelectorAll('#orm-fleet-rows tr')];
            const filter = () => rows.forEach(row => {
              row.hidden = !row.dataset.account.toLowerCase().includes(search.value.trim().toLowerCase())
                || (state.value !== '' && row.dataset.state !== state.value);
            });
            search.addEventListener('input', filter);
            state.addEventListener('change', filter);
            for (const formId of ['orm-fleet-batch-create', 'orm-fleet-batch-restore']) {
              const form = document.getElementById(formId);
              form?.addEventListener('submit', event => {
                const selected = document.querySelectorAll(`input[form="${formId}"]:checked`).length;
                if (selected < 1 || selected > 2) {
                  event.preventDefault();
                  window.alert('Select one or two running accounts on this page.');
                }
              });
            }
          })();
        </script>
        <?php else: ?>
          <p>No ORM-managed instances have been initialized.</p>
        <?php endif; ?>
      <?php endif; ?>
      <p>This root-only view lists verified account names, normalized states, and bounded snapshot metadata. Every service and backup action is validated against trusted cPanel identity by the broker; restores use a per-account safety snapshot and rollback path. Batch operations affect at most two running accounts on the visible page and report each outcome separately. Diagnostic and summary probes use fixed reads and validated counters only. Actions are audited and do not expose service paths, credentials, Redis keys, or values.</p>
    </section>
    <?php endif; ?>
    <section aria-labelledby="orm-backends-title">
      <h2 id="orm-backends-title">Redis-compatible backends</h2>
      <table>
        <thead><tr><th scope="col">Backend</th><th scope="col">Binary</th><th scope="col">Version</th><th scope="col">Service state</th></tr></thead>
        <tbody>
          <?php foreach ($report['backends'] as $backend): ?>
            <tr>
              <th scope="row"><?= htmlspecialchars($backend['label'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></th>
              <td><?= htmlspecialchars($backend['status'] === 'detected' ? (string)$backend['server_binary'] : 'Not detected in known paths', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
              <td><?= htmlspecialchars($backend['version'] ?? 'Unknown', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
              <td><?= htmlspecialchars($backend['service']['status'] . ($backend['service']['unit'] ? ' · ' . $backend['service']['unit'] : ''), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
            </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
      <p>Discovery checks common fixed paths and systemd units. A missing match does not prove that a backend is absent.</p>
      <p>Discovery queries fixed binary version output and systemd service state. It does not change services or read account data, Redis configuration, credentials, or Redis data.</p>
    </section>
    <section aria-labelledby="orm-policy-title">
      <h2 id="orm-policy-title">Default backend for new instances</h2>
      <?php if (!$rootAuthorized): ?>
        <p role="status">Only the root WHM administrator can change the server-wide backend choice.</p>
      <?php else: ?>
      <?php if ($policyMessage !== null): ?><p role="status"><?= htmlspecialchars($policyMessage, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p><?php endif; ?>
      <?php if ($policy === null): ?>
        <p>No backend is selected yet. Choose an installed backend before users initialize instances. Existing services are never changed by this setting.</p>
      <?php else: ?>
        <p>New ORM instances will use <strong><?= htmlspecialchars(ucfirst($policy), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong>. Existing services are unchanged.</p>
      <?php endif; ?>
      <form method="post">
        <input type="hidden" name="orm_action" value="backend.select">
        <label for="orm-backend">Backend</label>
        <select id="orm-backend" name="backend" required>
          <?php foreach ($report['backends'] as $backend): ?>
            <?php if ($backend['status'] === 'detected'): ?>
              <option value="<?= htmlspecialchars($backend['id'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>"<?= $policy === $backend['id'] ? ' selected' : '' ?>><?= htmlspecialchars($backend['label'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></option>
            <?php endif; ?>
          <?php endforeach; ?>
        </select>
        <button type="submit">Save backend choice</button>
      </form>
      <p>This setting selects the backend for future instances only. It does not install packages or migrate existing data.</p>
      <?php endif; ?>
    </section>
    <section aria-labelledby="orm-provider-policy-title">
      <h2 id="orm-provider-policy-title">Package resource policy</h2>
      <?php if (!$rootAuthorized): ?>
        <p role="status">Only the root WHM administrator can view or change provider package limits.</p>
      <?php elseif ($providerPolicy === null): ?>
        <p role="alert">The root-owned provider policy could not be verified. No provider limits are being changed.</p>
      <?php else: ?>
        <?php if ($providerPolicyMessage !== null): ?><p role="status"><?= htmlspecialchars($providerPolicyMessage, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p><?php endif; ?>
        <p>Mode: <strong><?= htmlspecialchars($providerPolicy['mode'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong>. Report-only logs policy violations without blocking. Warn allows the operation and shows a fixed notice in cPanel. Enforce blocks new provisions that exceed package or reseller limits and memory changes above package caps. Existing instances are grandfathered and are never rewritten by a policy change.</p>
        <h3>Default package rule</h3>
        <form method="post">
          <input type="hidden" name="orm_action" value="provider.policy.update">
          <input type="hidden" name="provider_rule_action" value="default">
          <label for="orm-provider-mode">Policy mode</label>
          <select id="orm-provider-mode" name="provider_mode" required>
            <option value="report-only"<?= $providerPolicy['mode'] === 'report-only' ? ' selected' : '' ?>>Report-only</option>
            <option value="warn"<?= $providerPolicy['mode'] === 'warn' ? ' selected' : '' ?>>Warn</option>
            <option value="enforce"<?= $providerPolicy['mode'] === 'enforce' ? ' selected' : '' ?>>Enforce</option>
          </select>
          <label for="orm-provider-exposure">cPanel feature exposure</label>
          <select id="orm-provider-exposure" name="provider_exposure" required>
            <option value="simple"<?= $providerPolicy['exposure'] === 'simple' ? ' selected' : '' ?>>Simple · status, setup, lifecycle, endpoint and PHP</option>
            <option value="developer"<?= $providerPolicy['exposure'] === 'developer' ? ' selected' : '' ?>>Developer · metrics, presets, configuration, app helpers and diagnostics</option>
            <option value="advanced"<?= $providerPolicy['exposure'] === 'advanced' ? ' selected' : '' ?>>Advanced · developer features plus backups and restore</option>
          </select>
          <p>Exposure only changes which controls are shown. It does not grant access or change broker permissions. If the exposure setting cannot be verified, cPanel uses Simple.</p>
          <label><input type="checkbox" name="default_enabled" value="1"<?= $providerPolicy['default']['enabled'] ? ' checked' : '' ?>> Allow new instances for packages without a specific rule</label>
          <label for="orm-provider-default-memory">Default memory ceiling (MiB)</label>
          <input id="orm-provider-default-memory" name="default_memory_mib" type="number" min="8" max="64" step="1" required value="<?= (int) $providerPolicy['default']['max_memory_mib'] ?>">
          <label for="orm-provider-default-retention">Default snapshot retention</label>
          <input id="orm-provider-default-retention" name="default_backup_retention" type="number" min="2" max="3" step="1" required value="<?= (int) $providerPolicy['default']['backup_retention'] ?>">
          <button type="submit">Save default policy</button>
        </form>
        <h3>Provider branding</h3>
        <p>White-label the cPanel screen with a product name, PNG logo, HTTPS support link, four clearly labelled theme colors, and accessible color palettes. The preview updates as you edit; cPanel receives only these display settings.</p>
        <form method="post" enctype="multipart/form-data" id="orm-branding-form">
          <input type="hidden" name="orm_action" value="provider.policy.update">
          <input type="hidden" name="provider_rule_action" value="save-branding">
          <input type="hidden" name="provider_mode" value="<?= htmlspecialchars($providerPolicy['mode'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <input type="hidden" name="default_memory_mib" value="<?= (int) $providerPolicy['default']['max_memory_mib'] ?>">
          <input type="hidden" name="default_backup_retention" value="<?= (int) $providerPolicy['default']['backup_retention'] ?>">
          <?php if ($providerPolicy['default']['enabled']): ?><input type="hidden" name="default_enabled" value="1"><?php endif; ?>
          <label for="orm-branding-name">Product name</label>
          <input id="orm-branding-name" name="branding_product_name" type="text" maxlength="48" pattern="[A-Za-z0-9][A-Za-z0-9 .&amp;()+/_-]{0,47}" required value="<?= htmlspecialchars($providerPolicy['branding']['product_name'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <label for="orm-branding-support">Support URL (HTTPS)</label>
          <input id="orm-branding-support" name="branding_support_url" type="url" maxlength="200" placeholder="https://support.example.com/redis" value="<?= htmlspecialchars($providerPolicy['branding']['support_url'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <label for="orm-branding-preset">Brand color preset</label>
          <select id="orm-branding-preset" name="branding_preset">
            <?php foreach (['custom' => 'Custom', 'underhost' => 'UnderHost-inspired', 'redis' => 'Redis-inspired', 'valkey' => 'Valkey-inspired', 'orm' => 'ORM red'] as $value => $label): ?>
              <option value="<?= $value ?>"<?= $providerPolicy['branding']['preset'] === $value ? ' selected' : '' ?>><?= $label ?></option>
            <?php endforeach; ?>
          </select>
          <label for="orm-branding-primary">Primary action color</label>
          <input id="orm-branding-primary" name="branding_primary_color" type="color" required value="<?= htmlspecialchars($providerPolicy['branding']['primary_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <label for="orm-branding-secondary">Link color</label>
          <input id="orm-branding-secondary" name="branding_secondary_color" type="color" required value="<?= htmlspecialchars($providerPolicy['branding']['secondary_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <label for="orm-branding-surface">Panel background color</label>
          <input id="orm-branding-surface" name="branding_surface_color" type="color" required value="<?= htmlspecialchars($providerPolicy['branding']['surface_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <label for="orm-branding-text">Text color</label>
          <input id="orm-branding-text" name="branding_text_color" type="color" required value="<?= htmlspecialchars($providerPolicy['branding']['text_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <p>Each preset changes colors only. Choose your own logo and product name separately. Foreground colors must keep at least 4.5:1 contrast against the panel background; action text must also contrast against white.</p>
          <label for="orm-branding-logo">Logo (PNG, 16–512 px wide × 16–256 px high, up to 32 KiB)</label>
          <input id="orm-branding-logo" name="branding_logo" type="file" accept="image/png" aria-describedby="orm-branding-logo-help">
          <p id="orm-branding-logo-help">SVG and other active image formats are not accepted. A transparent PNG works best.</p>
          <?php if ($providerPolicy['branding']['logo_png_base64'] !== ''): ?>
            <label><input type="checkbox" name="branding_clear_logo" value="1"> Remove the current logo</label>
          <?php endif; ?>
          <label><input type="checkbox" name="branding_footer_visible" value="1"<?= $providerPolicy['branding']['footer_visible'] ? ' checked' : '' ?>> Show product name and support link in the cPanel footer</label>
          <div class="orm-branding-preview" id="orm-branding-preview" style="--orm-preview-primary: <?= htmlspecialchars($providerPolicy['branding']['primary_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; --orm-preview-secondary: <?= htmlspecialchars($providerPolicy['branding']['secondary_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; --orm-preview-surface: <?= htmlspecialchars($providerPolicy['branding']['surface_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; --orm-preview-text: <?= htmlspecialchars($providerPolicy['branding']['text_color'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
            <div class="orm-branding-preview-title"><img id="orm-branding-preview-logo" alt=""<?= $providerPolicy['branding']['logo_png_base64'] !== '' ? ' src="data:image/png;base64,' . htmlspecialchars($providerPolicy['branding']['logo_png_base64'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') . '"' : ' hidden' ?>><strong id="orm-branding-preview-name"><?= htmlspecialchars($providerPolicy['branding']['product_name'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong></div>
            <div class="orm-branding-preview-body"><span>Cache status</span><strong>Online</strong><button type="button" tabindex="-1">Manage cache</button></div>
            <div class="orm-branding-preview-footer" id="orm-branding-preview-footer"><span id="orm-branding-preview-footer-name"><?= htmlspecialchars($providerPolicy['branding']['product_name'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></span><a id="orm-branding-preview-support"<?= $providerPolicy['branding']['support_url'] !== '' ? ' href="' . htmlspecialchars($providerPolicy['branding']['support_url'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') . '"' : ' hidden' ?>>Support</a></div>
          </div>
          <button type="submit">Save branding</button>
        </form>
        <script>
          (() => {
            const form = document.getElementById('orm-branding-form');
            if (!form) return;
            const name = form.querySelector('#orm-branding-name');
            const support = form.querySelector('#orm-branding-support');
            const primary = form.querySelector('#orm-branding-primary');
            const secondary = form.querySelector('#orm-branding-secondary');
            const surface = form.querySelector('#orm-branding-surface');
            const text = form.querySelector('#orm-branding-text');
            const preset = form.querySelector('#orm-branding-preset');
            const preview = form.querySelector('#orm-branding-preview');
            const previewName = form.querySelector('#orm-branding-preview-name');
            const footerName = form.querySelector('#orm-branding-preview-footer-name');
            const previewSupport = form.querySelector('#orm-branding-preview-support');
            const logoInput = form.querySelector('#orm-branding-logo');
            const previewLogo = form.querySelector('#orm-branding-preview-logo');
            const refresh = () => {
              const productName = name.value || 'Open Redis Manager';
              previewName.textContent = productName;
              footerName.textContent = productName;
              preview.style.setProperty('--orm-preview-primary', primary.value);
              preview.style.setProperty('--orm-preview-secondary', secondary.value);
              preview.style.setProperty('--orm-preview-surface', surface.value);
              preview.style.setProperty('--orm-preview-text', text.value);
              previewSupport.hidden = support.value === '';
              if (support.value !== '') previewSupport.href = support.value;
              const footer = form.querySelector('[name="branding_footer_visible"]');
              form.querySelector('#orm-branding-preview-footer').hidden = !footer.checked;
            };
            form.addEventListener('input', refresh);
            const palettes = {
              orm: { primary: '#C92319', secondary: '#A91F18', surface: '#FFFFFF', text: '#172536' },
              underhost: { primary: '#173F55', secondary: '#1E6580', surface: '#F4F8FA', text: '#173042' },
              redis: { primary: '#C4281F', secondary: '#9F211A', surface: '#FFF9F8', text: '#302625' },
              valkey: { primary: '#24489D', secondary: '#1D5BA8', surface: '#F5F8FF', text: '#172B45' },
            };
            preset.addEventListener('change', () => {
              const palette = palettes[preset.value];
              if (palette) {
                primary.value = palette.primary;
                secondary.value = palette.secondary;
                surface.value = palette.surface;
                text.value = palette.text;
              }
              refresh();
            });
            [primary, secondary, surface, text].forEach((input) => input.addEventListener('input', () => {
              preset.value = 'custom';
              refresh();
            }));
            logoInput.addEventListener('change', () => {
              const file = logoInput.files && logoInput.files[0];
              if (!file) return;
              const reader = new FileReader();
              reader.addEventListener('load', () => {
                if (typeof reader.result === 'string' && reader.result.startsWith('data:image/png;base64,')) {
                  previewLogo.src = reader.result;
                  previewLogo.hidden = false;
                }
              });
              reader.readAsDataURL(file);
            });
            refresh();
          })();
        </script>
        <style>
          .orm-branding-preview { max-width: 520px; margin: 18px 0; padding: 18px; border: 1px solid #dce3ec; border-radius: 10px; background: var(--orm-preview-surface); color: var(--orm-preview-text); }
          .orm-branding-preview-title { display: flex; align-items: center; gap: 10px; color: var(--orm-preview-primary); font-size: 20px; }
          .orm-branding-preview-title img { width: 40px; height: 40px; object-fit: contain; }
          .orm-branding-preview-body { display: flex; align-items: center; gap: 12px; margin-top: 16px; padding: 14px; border-radius: 8px; background: var(--orm-preview-surface); color: var(--orm-preview-text); }
          .orm-branding-preview-body strong { color: #176b3a; }
          .orm-branding-preview-body button { margin-left: auto; border: 0; border-radius: 6px; padding: 8px 12px; background: var(--orm-preview-primary); color: #fff; }
          .orm-branding-preview-footer { display: flex; justify-content: space-between; gap: 12px; margin-top: 14px; padding: 12px 10px; border-radius: 7px; background: var(--orm-preview-surface); color: var(--orm-preview-text); font-size: 12px; }
          .orm-branding-preview-footer a { color: var(--orm-preview-secondary); }
          #orm-branding-logo { display: block; margin: 8px 0; }
        </style>
        <h3>Package-specific rule</h3>
        <p>Use the exact package name from cPanel. A package-specific rule replaces the default values for that package.</p>
        <form method="post">
          <input type="hidden" name="orm_action" value="provider.policy.update">
          <input type="hidden" name="provider_rule_action" value="save-package">
          <input type="hidden" name="provider_mode" value="<?= htmlspecialchars($providerPolicy['mode'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <input type="hidden" name="default_memory_mib" value="<?= (int) $providerPolicy['default']['max_memory_mib'] ?>">
          <input type="hidden" name="default_backup_retention" value="<?= (int) $providerPolicy['default']['backup_retention'] ?>">
          <?php if ($providerPolicy['default']['enabled']): ?><input type="hidden" name="default_enabled" value="1"><?php endif; ?>
          <label for="orm-provider-package">cPanel package</label>
          <input id="orm-provider-package" name="package_name" type="text" maxlength="64" pattern="[A-Za-z0-9_.-]+" required>
          <label><input type="checkbox" name="package_enabled" value="1" checked> Allow new instances for this package</label>
          <label for="orm-provider-package-memory">Memory ceiling (MiB)</label>
          <input id="orm-provider-package-memory" name="package_memory_mib" type="number" min="8" max="64" step="1" required value="64">
          <label for="orm-provider-package-retention">Snapshot retention</label>
          <input id="orm-provider-package-retention" name="package_backup_retention" type="number" min="2" max="3" step="1" required value="3">
          <button type="submit">Save package rule</button>
        </form>
        <?php if ($providerPolicy['packages'] !== []): ?>
          <h3>Configured package rules</h3>
          <table>
            <thead><tr><th scope="col">Package</th><th scope="col">New instances</th><th scope="col">Memory ceiling</th><th scope="col">Snapshot retention</th><th scope="col">Action</th></tr></thead>
            <tbody>
              <?php foreach ($providerPolicy['packages'] as $packageName => $limits): ?>
                <tr>
                  <th scope="row"><?= htmlspecialchars($packageName, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></th>
                  <td><?= $limits['enabled'] ? 'Allowed' : 'Disabled' ?></td>
                  <td><?= (int) $limits['max_memory_mib'] ?> MiB</td>
                  <td><?= (int) $limits['backup_retention'] ?></td>
                  <td>
                    <form method="post">
                      <input type="hidden" name="orm_action" value="provider.policy.update">
                      <input type="hidden" name="provider_rule_action" value="remove-package">
                      <input type="hidden" name="provider_mode" value="<?= htmlspecialchars($providerPolicy['mode'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                      <input type="hidden" name="package_name" value="<?= htmlspecialchars($packageName, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                      <input type="hidden" name="default_memory_mib" value="<?= (int) $providerPolicy['default']['max_memory_mib'] ?>">
                      <input type="hidden" name="default_backup_retention" value="<?= (int) $providerPolicy['default']['backup_retention'] ?>">
                      <?php if ($providerPolicy['default']['enabled']): ?><input type="hidden" name="default_enabled" value="1"><?php endif; ?>
                      <button type="submit">Remove rule</button>
                    </form>
                  </td>
                </tr>
              <?php endforeach; ?>
            </tbody>
          </table>
        <?php else: ?>
          <p>No package-specific rules are configured.</p>
        <?php endif; ?>
        <h3>Reseller quotas</h3>
        <p>Set maximum configured instances and aggregate configured memory for a trusted cPanel <code>OWNER</code>. Stopped instances count. Enter <code>0</code> for no cap. Quotas apply to new provisioning only; existing accounts remain unchanged.</p>
        <form method="post">
          <input type="hidden" name="orm_action" value="provider.policy.update">
          <input type="hidden" name="provider_rule_action" value="save-reseller">
          <input type="hidden" name="provider_mode" value="<?= htmlspecialchars($providerPolicy['mode'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <input type="hidden" name="default_memory_mib" value="<?= (int) $providerPolicy['default']['max_memory_mib'] ?>">
          <input type="hidden" name="default_backup_retention" value="<?= (int) $providerPolicy['default']['backup_retention'] ?>">
          <?php if ($providerPolicy['default']['enabled']): ?><input type="hidden" name="default_enabled" value="1"><?php endif; ?>
          <label for="orm-provider-reseller-owner">Trusted reseller OWNER name</label>
          <input id="orm-provider-reseller-owner" name="reseller_owner" type="text" maxlength="16" pattern="[A-Za-z0-9_-]{1,16}" autocomplete="off" required>
          <label for="orm-provider-reseller-instances">Maximum configured instances</label>
          <input id="orm-provider-reseller-instances" name="reseller_max_instances" type="number" min="0" max="100000" step="1" required value="0">
          <label for="orm-provider-reseller-memory">Maximum aggregate memory (MiB)</label>
          <input id="orm-provider-reseller-memory" name="reseller_max_memory_mib" type="number" min="0" max="1000000" step="1" required value="0">
          <button type="submit">Save reseller quota</button>
        </form>
        <?php if (!is_array($resellerSummary) || ($resellerSummary['success'] ?? false) !== true): ?>
          <p role="status">Current reseller usage is unavailable. Quota changes still apply only when the broker can verify usage safely.</p>
        <?php elseif ($resellerSummary['resellers'] === []): ?>
          <p>No managed reseller accounts or reseller quota rules are currently present.</p>
        <?php else: ?>
          <table>
            <thead><tr><th scope="col">Reseller OWNER</th><th scope="col">Configured instances</th><th scope="col">Active instances</th><th scope="col">Memory in use</th><th scope="col">Instance cap</th><th scope="col">Memory cap</th><th scope="col">Action</th></tr></thead>
            <tbody>
              <?php foreach ($resellerSummary['resellers'] as $reseller): ?>
                <tr>
                  <th scope="row"><code><?= htmlspecialchars($reseller['owner'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></th>
                  <td><?= (int) $reseller['account_count'] ?></td>
                  <td><?= (int) $reseller['active_instances'] ?></td>
                  <td><?= (int) $reseller['memory_mib'] ?> MiB</td>
                  <td><?= (int) $reseller['max_instances'] === 0 ? 'Unlimited' : (int) $reseller['max_instances'] ?></td>
                  <td><?= (int) $reseller['max_memory_mib'] === 0 ? 'Unlimited' : (int) $reseller['max_memory_mib'] . ' MiB' ?></td>
                  <td>
                    <?php if (isset($providerPolicy['resellers'][$reseller['owner']])): ?>
                      <form method="post">
                        <input type="hidden" name="orm_action" value="provider.policy.update">
                        <input type="hidden" name="provider_rule_action" value="remove-reseller">
                        <input type="hidden" name="provider_mode" value="<?= htmlspecialchars($providerPolicy['mode'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                        <input type="hidden" name="reseller_owner" value="<?= htmlspecialchars($reseller['owner'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                        <input type="hidden" name="default_memory_mib" value="<?= (int) $providerPolicy['default']['max_memory_mib'] ?>">
                        <input type="hidden" name="default_backup_retention" value="<?= (int) $providerPolicy['default']['backup_retention'] ?>">
                        <?php if ($providerPolicy['default']['enabled']): ?><input type="hidden" name="default_enabled" value="1"><?php endif; ?>
                        <button type="submit">Remove quota</button>
                      </form>
                    <?php else: ?>
                      <span>—</span>
                    <?php endif; ?>
                  </td>
                </tr>
              <?php endforeach; ?>
            </tbody>
          </table>
        <?php endif; ?>
        <p>Provider policy is stored in a private root-owned file. Changes are recorded in the server log. Reseller identity and usage come from trusted account records and root-owned instance manifests; no account list or provider limits are sent to cPanel users.</p>
      <?php endif; ?>
    </section>
    <section aria-labelledby="orm-audit-title">
      <h2 id="orm-audit-title">ORM audit log</h2>
      <p>Search retained, recognized ORM events from the host journal. Filters and exports are limited to seven UTC days. An empty result does not prove that no activity occurred.</p>
      <?php if ($auditMessage !== null): ?><p role="alert"><?= htmlspecialchars($auditMessage, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p><?php endif; ?>
      <form method="post">
        <input type="hidden" name="orm_audit_action" value="search">
        <label for="orm-audit-from">From (UTC)</label>
        <input id="orm-audit-from" name="audit_from" type="date" value="<?= htmlspecialchars($auditForm['from'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" required>
        <label for="orm-audit-to">Through (UTC)</label>
        <input id="orm-audit-to" name="audit_to" type="date" value="<?= htmlspecialchars($auditForm['to'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" required>
        <label for="orm-audit-account">Account</label>
        <input id="orm-audit-account" name="audit_account" type="text" maxlength="16" pattern="[A-Za-z0-9_-]{1,16}" value="<?= htmlspecialchars($auditForm['account'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" placeholder="Any account or global">
        <label for="orm-audit-action">Action</label>
        <select id="orm-audit-action" name="audit_action">
          <option value="">All actions</option>
          <?php foreach (['start','stop','restart','backup.create','backup.restore','migration.to-valkey','diagnostics.read','recovery.scan','recovery.start','auth.rotate','auth.disable','provider.default','provider.package.save','provider.package.remove','provider.reseller.save','provider.reseller.remove','provider.branding.save','backend.select','policy.violation','security.report'] as $action): ?>
            <option value="<?= htmlspecialchars($action, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>"<?= $auditForm['action'] === $action ? ' selected' : '' ?>><?= htmlspecialchars($action, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></option>
          <?php endforeach; ?>
        </select>
        <label for="orm-audit-result">Result</label>
        <input id="orm-audit-result" name="audit_result" type="text" maxlength="48" pattern="[a-z][a-z0-9_-]{0,47}" value="<?= htmlspecialchars($auditForm['result'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" placeholder="Any result">
        <button type="submit">Search audit log</button>
      </form>
      <?php if (is_array($auditResult) && ($auditResult['success'] ?? false) === true): ?>
        <p role="status"><?= (int) $auditResult['record_count'] ?> records in range<?= $auditResult['partial'] ? '; coverage is partial' : '' ?>.</p>
        <ul>
          <?php foreach ($auditResult['sources'] as $source): ?>
            <li><code><?= htmlspecialchars($source['identifier'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code>: <?= htmlspecialchars($source['status'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>; <?= (int) $source['parsed_events'] ?> recognized events; <?= (int) $source['unrecognized_rows'] ?> unrecognized rows<?= $source['reason'] !== null ? '; ' . htmlspecialchars($source['reason'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') : '' ?>.</li>
          <?php endforeach; ?>
        </ul>
        <?php if ($auditResult['partial']): ?><p role="alert">Some source data was unavailable, truncated, or unrecognized. Treat these results as incomplete.</p><?php endif; ?>
        <form method="post">
          <input type="hidden" name="orm_audit_action" value="export">
          <input type="hidden" name="audit_from" value="<?= htmlspecialchars($auditForm['from'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <input type="hidden" name="audit_to" value="<?= htmlspecialchars($auditForm['to'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <input type="hidden" name="audit_account" value="<?= htmlspecialchars($auditForm['account'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <input type="hidden" name="audit_action" value="<?= htmlspecialchars($auditForm['action'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <input type="hidden" name="audit_result" value="<?= htmlspecialchars($auditForm['result'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
          <button type="submit">Download normalized JSON</button>
        </form>
        <?php $auditRows = array_slice($auditResult['records'], $auditPage * 50, 50); ?>
        <?php if ($auditRows === []): ?>
          <p>No retained recognized ORM events match these filters.</p>
        <?php else: ?>
          <table>
            <thead><tr><th scope="col">Time (UTC)</th><th scope="col">Source</th><th scope="col">Actor UID</th><th scope="col">Account</th><th scope="col">Action</th><th scope="col">Result</th><th scope="col">State</th></tr></thead>
            <tbody>
              <?php foreach ($auditRows as $event): ?>
                <tr>
                  <td><time datetime="<?= htmlspecialchars($event['timestamp_utc'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>"><?= htmlspecialchars($event['timestamp_utc'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></time></td>
                  <td><code><?= htmlspecialchars($event['source'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></td>
                  <td><?= htmlspecialchars($event['actor'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
                  <td><?= htmlspecialchars($event['account'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
                  <td><code><?= htmlspecialchars($event['action'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></td>
                  <td><?= htmlspecialchars($event['result'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
                  <td><?= htmlspecialchars($event['state'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
                </tr>
              <?php endforeach; ?>
            </tbody>
          </table>
          <?php if ($auditPage > 0 || count($auditResult['records']) > ($auditPage + 1) * 50): ?>
            <form method="post">
              <input type="hidden" name="orm_audit_action" value="search">
              <input type="hidden" name="audit_from" value="<?= htmlspecialchars($auditForm['from'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
              <input type="hidden" name="audit_to" value="<?= htmlspecialchars($auditForm['to'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
              <input type="hidden" name="audit_account" value="<?= htmlspecialchars($auditForm['account'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
              <input type="hidden" name="audit_action" value="<?= htmlspecialchars($auditForm['action'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
              <input type="hidden" name="audit_result" value="<?= htmlspecialchars($auditForm['result'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
              <button name="audit_page" value="<?= max(0, $auditPage - 1) ?>"<?= $auditPage === 0 ? ' disabled' : '' ?>>Previous</button>
              <span>Page <?= $auditPage + 1 ?> of <?= max(1, (int) ceil(count($auditResult['records']) / 50)) ?></span>
              <button name="audit_page" value="<?= $auditPage + 1 ?>"<?= count($auditResult['records']) <= ($auditPage + 1) * 50 ? ' disabled' : '' ?>>Next</button>
            </form>
          <?php endif; ?>
        <?php endif; ?>
        <h3>Coverage and retention</h3>
        <p>Only recognized events retained by <code>orm-broker</code> and <code>orm-whm</code> are shown. cPanel provisioning, configuration, start, and stop requests are not included. Host journal retention and forwarding determine how far back records exist. Raw messages, command output, Redis keys/values, passwords, host paths, and other journal identifiers are never shown or exported.</p>
      <?php endif; ?>
    </section>
  <?php endif; ?>
</main>
<?php WHM::footer(); ?>
