<?php
declare(strict_types=1);

require_once '/usr/local/cpanel/php/cpanel.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/AuthenticatedAccountContext.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerIdentityVerifier.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerClient.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/ConnectionDetails.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Security/SessionRequestGuard.php';

$cpanel = new CPANEL();
$account = \Orm\Cpanel\AuthenticatedAccountContext::fromLiveApi($cpanel);
$brokerVerified = $account !== null
    && (new \Orm\Cpanel\BrokerIdentityVerifier())->verifies($account->username());
$instanceClient = new \Orm\Cpanel\BrokerClient();
$actionResult = null;
$action = $_POST['orm_action'] ?? null;
if ($brokerVerified && \Orm\Security\SessionRequestGuard::allowsMutation($_SERVER)) {
    $allowedActions = ['provision', 'start', 'stop'];
    if (is_string($action) && in_array($action, $allowedActions, true)) {
        $actionResult = $instanceClient->request('instance.' . $action);
    }
}
$instanceStatus = $brokerVerified ? $instanceClient->request('instance.status') : null;
$liveMetrics = $brokerVerified && ($instanceStatus['state'] ?? null) === 'running'
    ? $instanceClient->request('instance.metrics')
    : null;
$connectionDetails = $brokerVerified
    ? \Orm\Cpanel\ConnectionDetails::forAccount($account->username(), $instanceStatus)
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
$hitCount = $hasLiveMetrics ? $liveMetrics['keyspace_hits'] + $liveMetrics['keyspace_misses'] : 0;
$hitRatio = $hasLiveMetrics && $hitCount > 0
    ? number_format(($liveMetrics['keyspace_hits'] / $hitCount) * 100, 1) . '%'
    : 'No lookups yet';
$uptimeDays = $hasLiveMetrics ? intdiv($liveMetrics['uptime_seconds'], 86400) : 0;
$uptimeHours = $hasLiveMetrics ? intdiv($liveMetrics['uptime_seconds'] % 86400, 3600) : 0;
$stateClass = match ($instanceStatus['state'] ?? null) {
    'running' => 'is-running',
    'starting', 'stopping' => 'is-pending',
    'failed' => 'is-failed',
    default => 'is-idle',
};
$errorMessages = [
    'backend_policy_required' => 'Your hosting provider must select an installed backend before you can initialize a cache.',
    'backend_unavailable' => 'The selected cache backend is not available right now. Contact your hosting provider.',
    'instance_exists' => 'An instance record already exists. Refresh this page or contact your hosting provider.',
    'not_configured' => 'Initialize the cache before starting it.',
    'rate_limited' => 'Please wait a moment before trying another action.',
    'service_failed' => 'The cache service could not complete that action. Refresh the page and check its status.',
    'storage_unavailable' => 'The cache could not be initialized because its private storage is unavailable.',
];
try {
    if (!$brokerVerified) {
        http_response_code(503);
    }
    print $cpanel->header('Open Redis Manager');
    ?>
    <main class="orm-entry" aria-labelledby="orm-title">
      <style>
        .orm-entry { max-width: 980px; margin: 24px auto; padding: 0 16px; color: #172235; }
        .orm-entry h1 { display: flex; align-items: center; gap: 10px; margin: 0 0 20px; font-size: 28px; }
        .orm-brand-icon { width: 34px; height: 34px; }
        .orm-card { padding: 24px; border: 1px solid #dce3ec; border-radius: 12px; background: #fff; box-shadow: 0 4px 18px rgb(23 34 53 / 6%); }
        .orm-state { display: inline-block; margin: 0 0 18px; padding: 6px 12px; border-radius: 999px; background: #e9f7ef; color: #176b3a; font-weight: 700; text-transform: capitalize; }
        .orm-state.is-pending { background: #fff3d9; color: #895a00; }
        .orm-state.is-failed { background: #fde9e9; color: #a42828; }
        .orm-state.is-idle { background: #edf1f6; color: #4f6078; }
        .orm-metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(165px, 1fr)); gap: 12px; margin: 18px 0 24px; }
        .orm-metric { min-width: 0; padding: 14px; border: 1px solid #e2e8f0; border-radius: 9px; background: #fbfcfe; }
        .orm-metric-label { display: flex; align-items: center; gap: 8px; color: #59677c; font-size: 13px; }
        .orm-metric-icon { width: 18px; height: 18px; color: #317a9d; }
        .orm-metric-value { display: block; margin-top: 8px; color: #172235; font-size: 20px; font-weight: 700; overflow-wrap: anywhere; }
        .orm-metrics-note { color: #59677c; font-size: 13px; }
        .orm-entry button { padding: 10px 16px; border: 0; border-radius: 7px; background: #2855d9; color: #fff; font-weight: 700; cursor: pointer; }
        .orm-entry button:disabled { background: #e1e6ee; color: #738096; cursor: not-allowed; }
        .orm-actions { display: flex; gap: 12px; }
        .orm-note { margin-top: 18px; color: #59677c; }
        .orm-connection { margin-top: 18px; }
        .orm-connection dl { display: grid; grid-template-columns: minmax(150px, 190px) 1fr; gap: 10px 18px; }
        .orm-connection dt { color: #59677c; }
        .orm-connection dd { margin: 0; overflow-wrap: anywhere; }
        .orm-connection details { margin-top: 14px; }
        .orm-connection summary { cursor: pointer; font-weight: 700; }
        .orm-connection pre { overflow-x: auto; padding: 14px; border-radius: 8px; background: #f2f5f9; }
        .orm-copy-actions { display: flex; justify-content: flex-end; margin-top: 10px; }
        .orm-connection .orm-copy-button { padding: 7px 11px; border: 1px solid #cbd5e1; background: #fff; color: #263b57; font-size: 13px; }
        .orm-copy-status:empty { display: none; }
        .orm-copy-status { color: #176b3a; }
        @media (max-width: 600px) { .orm-connection dl { grid-template-columns: 1fr; gap: 4px; } }
      </style>
      <h1 id="orm-title"><svg class="orm-brand-icon" viewBox="0 0 40 40" aria-hidden="true"><rect x="1" y="1" width="38" height="38" rx="11" fill="#22b8a7"/><path d="M9 13h22v4H9zm0 7h22v4H9zm0 7h14v4H9z" fill="#112238"/></svg>Open Redis Manager</h1>
      <?php if (!$brokerVerified): ?>
        <p role="alert">The account identity could not be verified by the local ORM broker. Reload the page or contact the server administrator.</p>
      <?php else: ?>
        <p>Verified cPanel account: <code><?= htmlspecialchars($account->username(), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></p>
        <section aria-labelledby="orm-ready-title">
          <h2 id="orm-ready-title">Your cache instance</h2>
          <?php if ($actionResult === null && ($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST'): ?>
            <p role="alert">The requested action was not accepted.</p>
          <?php elseif ($actionResult !== null && !$actionResult['success']): ?>
            <p role="alert"><?= htmlspecialchars($errorMessages[$actionResult['error'] ?? ''] ?? 'The action could not be completed. Contact your hosting provider.', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
          <?php elseif ($actionResult !== null): ?>
            <p role="status">Action accepted. Current state: <?= htmlspecialchars($actionResult['state'] ?? 'unknown', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>.</p>
          <?php endif; ?>
          <?php if ($instanceStatus === null || !$instanceStatus['success']): ?>
            <p role="alert">The local ORM service is temporarily unavailable. Contact the server administrator.</p>
          <?php else: ?>
            <div class="orm-card">
            <p class="orm-state <?= htmlspecialchars($stateClass, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?>"><?= htmlspecialchars(ucwords(str_replace('_', ' ', $instanceStatus['state'])), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></p>
            <?php if ($instanceStatus['state'] === 'running'): ?>
              <section aria-labelledby="orm-usage-title">
                <h3 id="orm-usage-title">Live usage</h3>
                <?php if ($hasLiveMetrics): ?>
                  <div class="orm-metrics">
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="3" width="16" height="18" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 8h8M8 12h8M8 16h5" stroke="currentColor" stroke-width="2"/></svg>Memory used</span><strong class="orm-metric-value"><?= htmlspecialchars($formatBytes($liveMetrics['memory_used_bytes']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 19V5m0 14h16M7 15l4-4 3 2 5-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>Memory peak</span><strong class="orm-metric-value"><?= htmlspecialchars($formatBytes($liveMetrics['memory_peak_bytes']), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M17 5a3 3 0 0 1 0 6m1 3a5 5 0 0 1 3 4v2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>Connected clients</span><strong class="orm-metric-value"><?= number_format($liveMetrics['connected_clients']) ?></strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 7v5l3 2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>Uptime</span><strong class="orm-metric-value"><?= number_format($uptimeDays) ?>d <?= str_pad((string) $uptimeHours, 2, '0', STR_PAD_LEFT) ?>h</strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 18h3l3-7 4 4 3-8h3" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>Operations per second</span><strong class="orm-metric-value"><?= number_format($liveMetrics['commands_per_second']) ?>/s</strong></div>
                    <div class="orm-metric"><span class="orm-metric-label"><svg class="orm-metric-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12l4 4L19 6" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></svg>Cache hit ratio</span><strong class="orm-metric-value"><?= htmlspecialchars($hitRatio, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></strong></div>
                  </div>
                  <p class="orm-metrics-note">Live sample from Redis-compatible INFO statistics. Refresh this page for a new sample; history is not stored yet.</p>
                <?php else: ?>
                  <p class="orm-metrics-note" role="status">Live usage metrics are temporarily unavailable. Refresh this page to try again.</p>
                <?php endif; ?>
              </section>
            <?php endif; ?>
            <?php if ($instanceStatus['state'] === 'not_configured'): ?>
              <p>Initialize a private Redis-compatible cache instance. The backend must first be selected by your hosting provider.</p>
              <form method="post">
                <input type="hidden" name="orm_action" value="provision">
                <button type="submit">Initialize cache</button>
              </form>
            <?php else: ?>
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
                    <dt>Authentication</dt><dd>Socket permissions; no Redis AUTH password is configured.</dd>
                  </dl>
                  <p class="orm-note">Only processes running as this cPanel account can access the socket. TCP is disabled. Confirm that the PHP runtime used by your site can see this path, especially if CageFS is enabled.</p>
                  <details open>
                    <summary>PHP with PhpRedis</summary>
                    <div class="orm-copy-actions"><button class="orm-copy-button" type="button" aria-label="Copy PHP with PhpRedis example" data-copy-target="orm-example-php" data-copy-label="PHP with PhpRedis">Copy example</button></div>
                    <pre><code id="orm-example-php"><?= htmlspecialchars($connectionDetails['php_example'], ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></pre>
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
                  <p id="orm-copy-status" class="orm-note orm-copy-status" role="status" aria-live="polite"></p>
                  <script>
                    (() => {
                      const status = document.getElementById('orm-copy-status');
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
              <p class="orm-note">Configuration editing, monitoring and backups are not enabled in this build yet.</p>
            <?php endif; ?>
            </div>
          <?php endif; ?>
        </section>
      <?php endif; ?>
    </main>
    <?php
    print $cpanel->footer();
} finally {
    $cpanel->end();
}
