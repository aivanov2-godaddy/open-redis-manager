<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Cpanel/HealthGuidance.php';

use Orm\Cpanel\HealthGuidance;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$status = ['success' => true, 'state' => 'running', 'config' => [
    'memory_mib' => 16, 'maxclients' => 40, 'maxmemory_policy' => 'allkeys-lru', 'timeout' => 0,
]];
$metrics = ['success' => true, 'stale' => false, 'memory_used_bytes' => 8 * 1024 * 1024,
    'connected_clients' => 10, 'keyspace_hits' => 90, 'keyspace_misses' => 10];

$clear = HealthGuidance::build($status, $metrics);
$assert($clear['state'] === 'clear' && count($clear['findings']) === 1,
    'return a bounded clear advisory when current data stays below thresholds');
$assert(str_contains($clear['findings'][0]['title'], 'No current advisory thresholds'),
    'describe threshold status without declaring the service healthy');

$memoryPressure = HealthGuidance::build($status, array_replace($metrics, ['memory_used_bytes' => (int) (16 * 1024 * 1024 * 0.9)]));
$assert($memoryPressure['state'] === 'review' && $memoryPressure['findings'][0]['severity'] === 'warning'
    && str_contains($memoryPressure['findings'][0]['detail'], '90%'), 'warn when memory reaches 85% of its configured ceiling');
$memoryBoundary = HealthGuidance::build($status, array_replace($metrics, [
    'memory_used_bytes' => (int) ceil(16 * 1024 * 1024 * 0.85),
]));
$assert(str_contains($memoryBoundary['findings'][0]['title'], 'Memory use is approaching'),
    'include the 85% configured-memory boundary in the advisory');

$clientPressure = HealthGuidance::build($status, array_replace($metrics, ['connected_clients' => 34]));
$assert(str_contains($clientPressure['findings'][0]['title'], 'clients are near'),
    'warn when connected clients reach 85% of the configured limit');

$lowHitRatio = HealthGuidance::build($status, array_replace($metrics, ['keyspace_hits' => 40, 'keyspace_misses' => 60]));
$assert(str_contains($lowHitRatio['findings'][0]['title'], 'below 50%'),
    'report cumulative hit ratio below 50% after at least 100 lookups');
$halfHitRatio = HealthGuidance::build($status, array_replace($metrics, ['keyspace_hits' => 50, 'keyspace_misses' => 50]));
$assert(!array_filter($halfHitRatio['findings'], static fn (array $finding): bool => str_contains($finding['title'], 'hit ratio')),
    'do not report a low-ratio finding at exactly 50%');
$fewLookups = HealthGuidance::build($status, array_replace($metrics, ['keyspace_hits' => 4, 'keyspace_misses' => 6]));
$assert(!array_filter($fewLookups['findings'], static fn (array $finding): bool => str_contains($finding['title'], 'hit ratio')),
    'do not assess hit ratio before 100 lookups');

$stale = HealthGuidance::build($status, array_replace($metrics, ['stale' => true, 'memory_used_bytes' => 16 * 1024 * 1024]));
$assert($stale['state'] === 'stale' && count($stale['findings']) === 1
    && str_contains($stale['findings'][0]['title'], 'paused for stale'),
    'suppress metric thresholds when only retained stale metrics are available');
$missing = HealthGuidance::build($status, ['success' => false]);
$assert($missing['state'] === 'unavailable', 'show missing metrics as unavailable instead of evaluating thresholds');
$unknownStatus = HealthGuidance::build(null, $metrics);
$assert($unknownStatus['state'] === 'unavailable', 'fail closed when the instance status is unknown');
$stopped = HealthGuidance::build(['success' => true, 'state' => 'stopped'], $metrics);
$assert($stopped['state'] === 'attention' && count($stopped['findings']) === 1,
    'avoid performance findings for a stopped instance');
$unconfigured = HealthGuidance::build(['success' => true, 'state' => 'not_configured'], null);
$assert($unconfigured['state'] === 'setup', 'guide an unconfigured account to initialize an instance');

$page = file_get_contents(dirname(__DIR__) . '/packaging/cpanel/files/orm/index.live.php');
$packageMap = file_get_contents(dirname(__DIR__) . '/packaging/lib.sh');
$assert(is_string($page) && str_contains($page, 'HealthGuidance.php')
    && str_contains($page, 'aria-labelledby="orm-health-title"'),
    'load and render the accessible health guidance section in the cPanel page');
$assert(is_string($packageMap) && str_contains($packageMap,
    'health_guidance "$ORM_REPO_ROOT/src/Orm/Cpanel/HealthGuidance.php" "$ORM_3RDPARTY/src/Orm/Cpanel/HealthGuidance.php" 644'),
    'include the health guidance class in the exact installed package manifest');
$assert(is_string($page) && str_contains($page, 'does not test application connectivity or guarantee cache performance'),
    'explain that advisory guidance does not verify application connectivity or guarantee performance');

fwrite(STDOUT, "cPanel health guidance checks passed: {$checks}\n");
