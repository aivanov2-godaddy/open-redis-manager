<?php
declare(strict_types=1);

require_once '/usr/local/cpanel/php/WHM.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmAcl.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Backend/BackendDiscovery.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Backend/BackendPolicyStore.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/SessionRequestGuard.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerClient.php';

$authenticatedUser = $_ENV['REMOTE_USER'] ?? getenv('REMOTE_USER');
$authenticatedUser = is_string($authenticatedUser) ? $authenticatedUser : null;
$authorized = \Orm\Security\WhmAcl::allowsAdministrativeAccess($authenticatedUser);
$rootAuthorized = $authorized && $authenticatedUser === 'root';
$report = $authorized ? (new \Orm\Backend\BackendDiscovery())->discover() : null;
$policyStore = new \Orm\Backend\BackendPolicyStore();
$policy = $rootAuthorized ? $policyStore->selectedBackend() : null;
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

if (!$authorized) {
    http_response_code(403);
}

WHM::header('Open Redis Manager', 0, 0);
?>
<style>.orm-entry h1{display:flex;align-items:center;gap:10px}</style>
<main class="orm-entry" aria-labelledby="orm-title">
  <h1 id="orm-title"><svg width="34" height="34" viewBox="0 0 128 128" aria-hidden="true">
  <defs>
    <linearGradient id="orm-red" x1="12" y1="8" x2="116" y2="120" gradientUnits="userSpaceOnUse">
      <stop stop-color="#F04438"/>
      <stop offset="1" stop-color="#C81E18"/>
    </linearGradient>
    <linearGradient id="orm-white" x1="38" y1="39" x2="88" y2="88" gradientUnits="userSpaceOnUse">
      <stop stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#FFF7F6"/>
    </linearGradient>
  </defs>

  <rect x="2" y="2" width="124" height="124" rx="34" fill="url(#orm-red)"/>
  <rect x="15" y="15" width="98" height="98" rx="28" fill="none" stroke="#FFFFFF" stroke-opacity=".18" stroke-width="2"/>

  <!-- An open cache orbit wraps three managed data layers. -->
  <path d="M82 27a42 42 0 1 0 17 34" fill="none" stroke="#FFFFFF" stroke-linecap="round" stroke-width="6"/>
  <path d="m78 19 15 1-7 13" fill="none" stroke="#FFFFFF" stroke-linecap="round" stroke-linejoin="round" stroke-width="6"/>

  <g fill="url(#orm-white)">
    <rect x="45" y="40" width="39" height="12" rx="6"/>
    <rect x="37" y="58" width="53" height="12" rx="6"/>
    <rect x="43" y="76" width="42" height="12" rx="6"/>
  </g>
  <g fill="#C81E18">
    <rect x="74" y="44" width="5" height="4" rx="2"/>
    <rect x="79" y="62" width="6" height="4" rx="2"/>
    <rect x="74" y="80" width="5" height="4" rx="2"/>
  </g>
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
  <?php endif; ?>
</main>
<?php WHM::footer(); ?>
