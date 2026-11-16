<?php
declare(strict_types=1);

require_once '/usr/local/cpanel/php/WHM.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmAcl.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Backend/BackendDiscovery.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Backend/BackendPolicyStore.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Backend/ProviderPolicyStore.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/SessionRequestGuard.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerClient.php';

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
$fleetControlMessage = null;
$fleetBackupMessage = null;
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
    } else {
        $policyMessage = 'The backend choice could not be saved. Choose an installed Redis-compatible backend.';
    }
}
$providerPolicyMessage = null;
if ($rootAuthorized && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)
    && ($_POST['orm_action'] ?? null) === 'provider.policy.update') {
    $providerAction = $_POST['provider_rule_action'] ?? null;
    $submittedMode = $_POST['provider_mode'] ?? null;
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
    if ($providerPolicy === null || !in_array($providerAction, ['default', 'save-package', 'remove-package'], true)
        || !in_array($submittedMode, ['report-only', 'enforce'], true)
        || $defaultMemory === null || $defaultRetention === null) {
        $providerPolicyMessage = 'The provider policy is unavailable or contains invalid values. No changes were saved.';
    } else {
        $updatedProviderPolicy = $providerPolicy;
        $updatedProviderPolicy['mode'] = $providerAction === 'default'
            ? $submittedMode : $providerPolicy['mode'];
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
        }

        if ($providerPolicyMessage === null) {
            if ($providerPolicyStore->save($updatedProviderPolicy)) {
                $providerPolicy = $providerPolicyStore->load();
                $providerPolicyMessage = $providerPolicy === null
                    ? 'The policy was written, but could not be re-read safely. Check the root-owned policy file.'
                    : 'Provider policy saved. Enforced changes affect new provisions, later memory changes, and future backup retention; existing instances were not rewritten.';
                error_log('ORM provider policy changed through root WHM; action=' . $providerAction);
            } else {
                $providerPolicyMessage = 'The provider policy could not be saved safely. No changes were applied.';
            }
        }
    }
}

if (!$authorized) {
    http_response_code(403);
}

WHM::header('Open Redis Manager', 0, 0);
?>
<style>.orm-entry h1{display:flex;align-items:center;gap:10px}</style>
<main class="orm-entry" aria-labelledby="orm-title">
  <h1 id="orm-title"><svg width="34" height="34" viewBox="0 0 256 256" aria-hidden="true">
  <defs><linearGradient id="orm-red" x1="24" y1="20" x2="232" y2="236" gradientUnits="userSpaceOnUse"><stop stop-color="#E5392D"/><stop offset="1" stop-color="#D92D20"/></linearGradient></defs>
  <rect x="4" y="4" width="248" height="248" rx="66" fill="url(#orm-red)"/>
  <path d="M164 49 190 64a13 13 0 0 1 7 12v97a13 13 0 0 1-7 12l-55 31a13 13 0 0 1-13 0l-55-31a13 13 0 0 1-7-12V83a13 13 0 0 1 7-12l25-14" fill="none" stroke="#fff" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="m128 66 40 23-40 23-40-23 40-23Z" fill="#fff"/><path d="m128 77 21 12-21 12-21-12 21-12Z" fill="#D92D20"/>
  <path d="m88 104 40 23 40-23v18l-40 23-40-23v-18Z" fill="#fff"/><path d="m99 126 29 17 29-17v7l-29 17-29-17v-7Z" fill="#D92D20"/>
  <path d="m88 144 40 23 40-23v18l-40 23-40-23v-18Z" fill="#fff"/><path d="m99 166 29 17 29-17v7l-29 17-29-17v-7Z" fill="#D92D20"/>
</svg>Open Redis Manager</h1>
  <?php if (!$authorized): ?>
    <p role="alert">Access denied. This page requires root-level WHM access.</p>
  <?php elseif ($report['status'] !== 'supported-platform'): ?>
    <p role="status">Backend discovery is unavailable on this platform.</p>
  <?php else: ?>
    <p>Live backend discovery from the authenticated WHM session.</p>
    <?php if ($rootAuthorized): ?>
    <section aria-labelledby="orm-fleet-title">
      <h2 id="orm-fleet-title">Managed ORM instances</h2>
      <?php if ($fleetControlMessage !== null): ?>
        <p role="<?= $fleetControlMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($fleetControlMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
      <?php endif; ?>
      <?php if ($fleetBackupMessage !== null): ?>
        <p role="<?= $fleetBackupMessage['type'] === 'error' ? 'alert' : 'status' ?>"><?= htmlspecialchars($fleetBackupMessage['text'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
      <?php endif; ?>
      <?php if ($fleetPage === null): ?>
        <p role="status">The managed-instance inventory is unavailable. Backend discovery and existing services are unchanged.</p>
      <?php else: ?>
        <p><?= htmlspecialchars((string) $fleetPage['total'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?> configured or unhealthy ORM accounts.</p>
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
          <option value="unhealthy">Unhealthy</option>
        </select>
        <p>Each row shows snapshots retained for that account. Backup and restore requests run per account and return that account's result; restore briefly interrupts service and may lose newer writes.</p>
        <table>
          <thead><tr><th scope="col">cPanel account</th><th scope="col">Instance state</th><th scope="col">Service actions</th><th scope="col">Backups and restore</th></tr></thead>
          <tbody id="orm-fleet-rows">
            <?php foreach ($fleetPage['entries'] as $entry): ?>
              <tr data-account="<?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>" data-state="<?= htmlspecialchars($entry['state'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>">
                <th scope="row"><?= htmlspecialchars($entry['username'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></th>
                <td><?= htmlspecialchars(ucfirst($entry['state']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></td>
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
          })();
        </script>
        <?php else: ?>
          <p>No ORM-managed instances have been initialized.</p>
        <?php endif; ?>
      <?php endif; ?>
      <p>This root-only view lists account names, normalized states, and each account's bounded snapshot metadata. Every service and backup action is validated against the trusted cPanel account by the broker; restore uses that account's safety snapshot and rollback path. Actions are audited and do not expose service paths, configuration, credentials, or Redis data.</p>
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
        <p>Mode: <strong><?= htmlspecialchars($providerPolicy['mode'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong>. Report-only records violations without blocking; enforce rejects new provisions and memory changes over the selected package cap. Existing instances are not rewritten.</p>
        <h3>Default package rule</h3>
        <form method="post">
          <input type="hidden" name="orm_action" value="provider.policy.update">
          <input type="hidden" name="provider_rule_action" value="default">
          <label for="orm-provider-mode">Policy mode</label>
          <select id="orm-provider-mode" name="provider_mode" required>
            <option value="report-only"<?= $providerPolicy['mode'] === 'report-only' ? ' selected' : '' ?>>Report-only</option>
            <option value="enforce"<?= $providerPolicy['mode'] === 'enforce' ? ' selected' : '' ?>>Enforce</option>
          </select>
          <label><input type="checkbox" name="default_enabled" value="1"<?= $providerPolicy['default']['enabled'] ? ' checked' : '' ?>> Allow new instances for packages without a specific rule</label>
          <label for="orm-provider-default-memory">Default memory ceiling (MiB)</label>
          <input id="orm-provider-default-memory" name="default_memory_mib" type="number" min="8" max="64" step="1" required value="<?= (int) $providerPolicy['default']['max_memory_mib'] ?>">
          <label for="orm-provider-default-retention">Default snapshot retention</label>
          <input id="orm-provider-default-retention" name="default_backup_retention" type="number" min="2" max="3" step="1" required value="<?= (int) $providerPolicy['default']['backup_retention'] ?>">
          <button type="submit">Save default policy</button>
        </form>
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
        <p>Provider policy is stored in a private root-owned file. Changes are recorded in the server log. Reseller instance quotas and exposure levels are not implemented yet.</p>
      <?php endif; ?>
    </section>
  <?php endif; ?>
</main>
<?php WHM::footer(); ?>
