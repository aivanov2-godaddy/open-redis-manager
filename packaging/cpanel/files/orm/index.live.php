<?php
declare(strict_types=1);

require_once '/usr/local/cpanel/php/cpanel.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/AuthenticatedAccountContext.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerIdentityVerifier.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerClient.php';
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
        .orm-entry button { padding: 10px 16px; border: 0; border-radius: 7px; background: #2855d9; color: #fff; font-weight: 700; cursor: pointer; }
        .orm-entry button:disabled { background: #e1e6ee; color: #738096; cursor: not-allowed; }
        .orm-actions { display: flex; gap: 12px; }
        .orm-note { margin-top: 18px; color: #59677c; }
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
              <p class="orm-note">The instance uses an account-private Unix socket. Connection snippets, configuration, monitoring and backups are not enabled in this build yet.</p>
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
