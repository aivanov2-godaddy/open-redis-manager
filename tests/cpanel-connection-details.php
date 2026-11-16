<?php
declare(strict_types=1);

require_once __DIR__ . '/../src/Orm/Cpanel/ConnectionDetails.php';

use Orm\Cpanel\ConnectionDetails;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$assert(ConnectionDetails::forAccount('demo', ['success' => true, 'state' => 'not_configured']) === null,
    'unprovisioned account has no connection details');
$assert(ConnectionDetails::forAccount('demo', ['success' => false, 'state' => 'running']) === null,
    'failed status has no connection details');
$assert(ConnectionDetails::forAccount('demo/../../root', ['success' => true, 'state' => 'running']) === null,
    'unsafe account name is rejected');

$details = ConnectionDetails::forAccount('demo', ['success' => true, 'state' => 'stopped']);
$assert(is_array($details), 'provisioned stopped instance has connection details');
$assert($details['socket_path'] === '/var/lib/orm-instances/demo/redis.sock', 'socket path is account-scoped');
$assert($details['database'] === 0, 'default database is zero');
$assert($details['authentication'] === 'unix_socket_permissions', 'authentication mode is explicit');
$assert(str_contains($details['php_example'], "->connect('/var/lib/orm-instances/demo/redis.sock')"),
    'PhpRedis snippet uses the account socket');
$assert(str_contains($details['php_example'], '$redis->select(0);'), 'PhpRedis snippet selects database zero');
$assert(!str_contains($details['php_example'], 'password') && !str_contains($details['php_example'], 'tcp://'),
    'snippet contains no password or TCP endpoint');
$assert(str_contains($details['node_example'], 'socket: { path: "/var/lib/orm-instances/demo/redis.sock" }'),
    'node-redis snippet uses a Unix socket');
$assert(str_contains($details['python_example'], "unix_socket_path='/var/lib/orm-instances/demo/redis.sock'"),
    'redis-py snippet uses a Unix socket');
$assert(!str_contains($details['node_example'], 'password') && !str_contains($details['python_example'], 'password'),
    'Node and Python snippets contain no password');
$assert(str_contains($details['wordpress_example'], "WP_REDIS_SCHEME', 'unix'")
    && str_contains($details['wordpress_example'], "WP_REDIS_PATH', '/var/lib/orm-instances/demo/redis.sock'")
    && str_contains($details['wordpress_example'], "WP_REDIS_DATABASE', 0"),
    'WordPress helper selects the account socket and database zero');
$assert(str_contains($details['wordpress_example'], 'WP_REDIS_PREFIX')
    && !str_contains($details['wordpress_example'], 'WP_REDIS_PASSWORD'),
    'WordPress helper scopes keys without inventing an authentication secret');
$assert(str_contains($details['litespeed_example'], 'Host: /var/lib/orm-instances/demo/redis.sock')
    && str_contains($details['litespeed_example'], 'Port: 0')
    && str_contains($details['litespeed_example'], 'Password: leave blank'),
    'LiteSpeed helper uses its documented Unix socket settings without a password');
$assert(str_contains($details['laravel_example'], 'REDIS_HOST=/var/lib/orm-instances/demo/redis.sock')
    && str_contains($details['laravel_example'], 'REDIS_PORT=0')
    && !str_contains($details['laravel_example'], 'REDIS_PASSWORD'),
    'Laravel helper uses the socket host and port zero without a password');
$assert(str_contains($details['magento_values'], 'server=/var/lib/orm-instances/demo/redis.sock')
    && str_contains($details['magento_values'], 'port=0')
    && str_contains($details['magento_values'], 'page_cache_database=1'),
    'Magento helper shows version-neutral socket values and separate cache databases');
$authDetails = ConnectionDetails::forAccount('demo', [
    'success' => true, 'state' => 'running', 'secret' => 'actual-secret-canary',
], true);
$assert(is_array($authDetails) && $authDetails['auth_configured']
    && $authDetails['authentication'] === 'unix_socket_permissions_and_redis_auth',
    'identify enabled AUTH while retaining the account-private socket transport');
$assert(str_contains($authDetails['php_example'], "->auth(getenv('ORM_REDIS_PASSWORD'))")
    && str_contains($authDetails['node_example'], 'password: process.env.ORM_REDIS_PASSWORD')
    && str_contains($authDetails['python_example'], 'password=os.environ["ORM_REDIS_PASSWORD"]'),
    'provide client-specific environment variable placeholders without embedding a real password');
$assert(str_contains($authDetails['wordpress_example'], 'WP_REDIS_PASSWORD')
    && str_contains($authDetails['litespeed_example'], 'Password: set to the ORM_REDIS_PASSWORD environment value')
    && str_contains($authDetails['laravel_example'], 'REDIS_PASSWORD=${ORM_REDIS_PASSWORD}')
    && str_contains($authDetails['magento_values'], 'password=<paste the rotated ORM password>'),
    'include password guidance for WordPress, LiteSpeed, Laravel, and Magento');
$assert(!str_contains(implode("\n", $authDetails), 'actual-secret-canary'),
    'never put a credential value into generated helper text');
$podmanDetails = ConnectionDetails::forSocket('demo', '/home/demo/ea-podman.d/ea-redis62.demo.01/redis.sock');
$assert(is_array($podmanDetails)
    && $podmanDetails['socket_path'] === '/home/demo/ea-podman.d/ea-redis62.demo.01/redis.sock'
    && str_contains($podmanDetails['php_example'], "->connect('/home/demo/ea-podman.d/ea-redis62.demo.01/redis.sock')"),
    'build application connection helpers for the current account Redis pod socket');
$valkeyPodmanDetails = ConnectionDetails::forSocket('demo', '/home/demo/ea-podman.d/ea-valkey72.demo.02/valkey.sock');
$assert(is_array($valkeyPodmanDetails) && str_contains($valkeyPodmanDetails['laravel_example'], 'REDIS_PORT=0'),
    'build application helpers for the current account Valkey pod socket');
$assert(ConnectionDetails::forSocket('demo', '/home/other/ea-podman.d/ea-redis62.other.01/redis.sock') === null
    && ConnectionDetails::forSocket('demo', '/var/lib/orm-instances/other/redis.sock') === null
    && ConnectionDetails::forSocket('demo', '/home/demo/ea-podman.d/ea-redis62.demo.01/../redis.sock') === null,
    'reject pod sockets outside the current cPanel account and unsafe paths');

$page = file_get_contents(dirname(__DIR__) . '/packaging/cpanel/files/orm/index.live.php');
$assert(is_string($page), 'read the installed cPanel page template');
foreach ([
    'orm-example-php' => 'Copy PHP with PhpRedis example',
    'orm-example-wordpress' => 'Copy WordPress and WooCommerce example',
    'orm-example-litespeed' => 'Copy LiteSpeed Cache settings',
    'orm-example-laravel' => 'Copy Laravel environment settings',
    'orm-example-magento' => 'Copy Magento connection values',
    'orm-example-node' => 'Copy Node.js with node-redis example',
    'orm-example-python' => 'Copy Python with redis-py example',
] as $target => $label) {
    $assert(str_contains($page, 'data-copy-target="' . $target . '"'), 'provide a copy button for ' . $target);
    $assert(str_contains($page, 'id="' . $target . '"'), 'provide a matching copy target for ' . $target);
    $assert(str_contains($page, 'aria-label="' . $label . '"'), 'give the ' . $target . ' copy action a specific accessible name');
}
$assert(str_contains($page, 'navigator.clipboard?.writeText'), 'copy through the browser clipboard API after a click');
$assert(str_contains($page, 'role="status" aria-live="polite"'), 'announce copy success and failure accessibly');
$assert(str_contains($page, 'Select and copy the example manually.'), 'explain the manual copy fallback');
$assert(str_contains($page, "request('instance.metrics')") && str_contains($page, "!== 'not_configured'"),
    'request current or stale metrics for every configured instance state');
$assert(str_contains($page, 'aria-labelledby="orm-usage-title"'), 'label the live usage section');
$assert(str_contains($page, 'Cache hit ratio') && str_contains($page, 'Operations per second'), 'show activity and hit-ratio metrics');
$assert(str_contains($page, 'Stale sample') && str_contains($page, 'sampled_at'), 'label stale values and show their sample time');
$assert(str_contains($page, 'This latest sample is saved for up to 30 days.')
    && str_contains($page, 'Hourly history'), 'explain latest-sample retention and the separate hourly history view');
$assert(str_contains($page, 'could not be saved for fallback use'), 'disclose a failed snapshot write to the account user');
$assert(str_contains($page, 'name="orm_preset"'), 'offer a preset when initializing an instance');
foreach (['generic', 'wordpress', 'laravel', 'magento', 'session'] as $preset) {
    $assert(str_contains($page, 'value="' . $preset . '"'), 'expose the ' . $preset . ' setup preset');
}
$assert(str_contains($page, "request('instance.provision', \$preset)"), 'send the selected preset through the broker client');
$assert(str_contains($page, 'name="orm_action" value="configure"'), 'provide a session-protected configuration form action');
$assert(str_contains($page, 'name="orm_memory_mib"') && str_contains($page, 'max="64"'), 'bound the memory field in the account UI');
$assert(str_contains($page, 'name="orm_maxmemory_policy"'), 'offer an eviction policy selector');
$assert(str_contains($page, 'name="orm_maxclients"') && str_contains($page, 'name="orm_timeout"'), 'expose the client and timeout controls');
$assert(str_contains($page, 'those evictions cannot be undone.'), 'warn that lowering memory can irreversibly evict keys');
$assert(str_contains($page, "request('instance.configure', null, ["), 'send configuration through the fixed broker operation');
$assert(str_contains($page, 'Configuration saved.'), 'announce configuration changes accessibly after they are accepted');
$assert(str_contains($page, 'name="orm_action" value="auth.rotate"')
    && str_contains($page, '$instanceClient->rotateAuth()'), 'offer one account-scoped, explicit POST rotation action');
$assert(str_contains($page, 'name="orm_action" value="auth.disable"')
    && str_contains($page, '$instanceClient->disableAuth()')
    && str_contains($page, 'confirm(\'Disable Redis AUTH?'), 'require an explicit confirmation before disabling AUTH');
$assert(str_contains($page, 'Cache-Control: no-store, private')
    && str_contains($page, 'window.addEventListener(\'pagehide\'')
    && str_contains($page, 'Copy the new Redis AUTH password'),
    'no-store the one-time response, clear it on page exit, and expose an explicit accessible copy action');

fwrite(STDOUT, "cPanel connection details checks passed: {$checks}\n");
