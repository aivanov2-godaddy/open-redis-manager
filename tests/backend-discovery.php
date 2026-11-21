<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Backend/BackendDiscovery.php';

use Orm\Backend\BackendDiscovery;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$assert(BackendDiscovery::availabilityStatus('/usr/bin/redis-server', '/usr/bin/redis-cli') === 'detected',
    'mark a native backend ready only when both server and matching CLI are present.');
$assert(BackendDiscovery::availabilityStatus('/usr/bin/redis-server', null) === 'server-only',
    'distinguish a missing CLI from a completely absent native server.');
$assert(BackendDiscovery::availabilityStatus(null, '/usr/bin/redis-cli') === 'client-only',
    'distinguish a missing server binary from a completely absent native CLI.');
$assert(BackendDiscovery::availabilityStatus(null, null) === 'not-detected',
    'report neither binary found as not detected rather than claiming global absence.');

fwrite(STDOUT, "Backend discovery checks passed: {$checks}\n");
