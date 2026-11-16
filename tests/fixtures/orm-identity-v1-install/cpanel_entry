<?php
declare(strict_types=1);

require_once '/usr/local/cpanel/php/cpanel.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/AuthenticatedAccountContext.php';
require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerIdentityVerifier.php';

$cpanel = new CPANEL();
$account = \Orm\Cpanel\AuthenticatedAccountContext::fromLiveApi($cpanel);
$brokerVerified = $account !== null
    && (new \Orm\Cpanel\BrokerIdentityVerifier())->verifies($account->username());
try {
    if (!$brokerVerified) {
        http_response_code(503);
    }
    print $cpanel->header('Open Redis Manager');
    ?>
    <main class="orm-entry" aria-labelledby="orm-title">
      <h1 id="orm-title">Open Redis Manager</h1>
      <?php if (!$brokerVerified): ?>
        <p role="alert">The account identity could not be verified by the local ORM broker. Reload the page or contact the server administrator.</p>
      <?php else: ?>
        <p>Verified cPanel account: <code><?= htmlspecialchars($account->username(), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8') ?></code></p>
        <section aria-labelledby="orm-ready-title">
          <h2 id="orm-ready-title">Redis account service is not connected</h2>
          <p>This build verifies the cPanel account context but does not yet read or change Redis, Valkey, or account instance state.</p>
          <p>No service commands or server changes were made by opening this page.</p>
        </section>
      <?php endif; ?>
    </main>
    <?php
    print $cpanel->footer();
} finally {
    $cpanel->end();
}
