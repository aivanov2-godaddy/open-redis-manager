<?php
declare(strict_types=1);

require_once '/usr/local/cpanel/php/cpanel.php';

$cpanel = new CPANEL();
try {
    print $cpanel->header('Open Redis Manager');
    ?>
    <main class="orm-entry" aria-labelledby="orm-title">
      <h1 id="orm-title">Open Redis Manager</h1>
      <p>This page is running inside the authenticated cPanel session.</p>
      <section aria-labelledby="orm-ready-title">
        <h2 id="orm-ready-title">Account manager not connected</h2>
        <p>This build does not yet read or change Redis, Valkey, or account state from cPanel.</p>
        <p>No service commands or server changes were made by opening this page.</p>
      </section>
    </main>
    <?php
    print $cpanel->footer();
} finally {
    $cpanel->end();
}
