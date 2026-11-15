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

$page = file_get_contents(dirname(__DIR__) . '/packaging/cpanel/files/orm/index.live.php');
$assert(is_string($page), 'read the installed cPanel page template');
foreach ([
    'orm-example-php' => 'Copy PHP with PhpRedis example',
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
$assert(str_contains($page, "request('instance.metrics')"), 'request live metrics only for a running instance');
$assert(str_contains($page, 'aria-labelledby="orm-usage-title"'), 'label the live usage section');
$assert(str_contains($page, 'Cache hit ratio') && str_contains($page, 'Operations per second'), 'show activity and hit-ratio metrics');
$assert(str_contains($page, 'history is not stored yet'), 'explain that current samples are not historical data');

fwrite(STDOUT, "cPanel connection details checks passed: {$checks}\n");
