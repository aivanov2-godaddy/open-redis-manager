<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Cpanel/BrokerClient.php';

use Orm\Cpanel\BrokerClient;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    $checks++;
    if (!$condition) {
        throw new RuntimeException($message);
    }
};

$requests = [];
$client = new BrokerClient(static function (string $request) use (&$requests): string {
    $requests[] = $request;
    return "{\"success\":true,\"state\":\"running\",\"version\":1}\n";
});
$status = $client->request('instance.status');
$assert($status === ['success' => true, 'state' => 'running', 'version' => 1], 'Parse a valid instance status response.');
$assert($requests[0] === "{\"operation\":\"instance.status\",\"version\":1}\n", 'Send a canonical operation with no account-supplied identity.');
$assert($client->request('instance.provision') === $status, 'Allow the fixed provision operation.');
$assert($requests[1] === "{\"operation\":\"instance.provision\",\"version\":1}\n", 'Provision requests contain no paths, settings, or usernames.');
$presetRequests = [];
$presetClient = new BrokerClient(static function (string $request) use (&$presetRequests): string {
    $presetRequests[] = $request;
    return "{\"preset\":\"wordpress\",\"state\":\"running\",\"success\":true,\"version\":1}\n";
});
$presetStatus = $presetClient->request('instance.provision', 'wordpress');
$assert($presetStatus === ['success' => true, 'state' => 'running', 'version' => 1, 'preset' => 'wordpress'],
    'Parse the selected account preset from the status response.');
$assert($presetRequests[0] === "{\"operation\":\"instance.provision\",\"preset\":\"wordpress\",\"version\":1}\n",
    'Send only the fixed provision operation and an allowlisted preset.');
$assert($presetClient->request('instance.provision', '../root') === null,
    'Reject unsupported preset values before sending a broker request.');
$assert(count($presetRequests) === 1, 'Do not send an invalid preset to the broker.');
$unexpectedPreset = new BrokerClient(static fn (string $request): string =>
    "{\"preset\":\"../root\",\"state\":\"running\",\"success\":true,\"version\":1}\n"
);
$assert($unexpectedPreset->request('instance.status') === null, 'Reject an invalid preset in a broker response.');
$config = ['memory_mib' => 48, 'maxmemory_policy' => 'allkeys-lru', 'maxclients' => 50, 'timeout' => 60];
$expectedConfig = ['maxclients' => 50, 'maxmemory_policy' => 'allkeys-lru', 'memory_mib' => 48, 'timeout' => 60];
$configRequests = [];
$configClient = new BrokerClient(static function (string $request) use (&$configRequests): string {
    $configRequests[] = $request;
    return "{\"config\":{\"maxclients\":50,\"maxmemory_policy\":\"allkeys-lru\",\"memory_mib\":48,\"timeout\":60},\"preset\":\"generic\",\"state\":\"running\",\"success\":true,\"version\":1}\n";
});
$configured = $configClient->request('instance.configure', null, $config);
$assert($configured['config'] === $expectedConfig, 'Parse a bounded configuration status response.');
$assert($configRequests[0] === "{\"maxclients\":50,\"maxmemory_policy\":\"allkeys-lru\",\"memory_mib\":48,\"operation\":\"instance.configure\",\"timeout\":60,\"version\":1}\n",
    'Serialize configuration fields in the canonical fixed schema.');
$assert($configClient->request('instance.configure', null, [...$config, 'memory_mib' => 65]) === null,
    'Reject an over-cap memory request before broker I/O.');
$assert(count($configRequests) === 1, 'Do not send invalid configuration values.');
$badConfigResponse = new BrokerClient(static fn (string $request): string =>
    "{\"config\":{\"maxclients\":50,\"maxmemory_policy\":\"allkeys-lru\",\"memory_mib\":65,\"timeout\":60},\"preset\":\"generic\",\"state\":\"running\",\"success\":true,\"version\":1}\n"
);
$assert($badConfigResponse->request('instance.status') === null, 'Reject over-cap settings in a broker response.');
$metricResponse = "{\"commands_per_second\":12,\"connected_clients\":3,\"keyspace_hits\":90,\"keyspace_misses\":10,\"memory_peak_bytes\":2097152,\"memory_used_bytes\":1048576,\"retained\":true,\"sampled_at\":1794760000,\"stale\":false,\"success\":true,\"uptime_seconds\":3600,\"version\":1}\n";
$metricsClient = new BrokerClient(static function (string $request) use (&$requests, $metricResponse): string {
    $requests[] = $request;
    return $metricResponse;
});
$metrics = $metricsClient->request('instance.metrics');
$assert($metrics['memory_used_bytes'] === 1048576 && $metrics['keyspace_hits'] === 90
    && $metrics['sampled_at'] === 1794760000 && $metrics['stale'] === false,
    'Parse the exact bounded fresh-metrics response.');
$assert($requests[2] === "{\"operation\":\"instance.metrics\",\"version\":1}\n",
    'Metrics requests contain no account identity or target path.');
$badMetrics = new BrokerClient(static fn (string $request): string =>
    "{\"commands_per_second\":-1,\"connected_clients\":3,\"keyspace_hits\":90,\"keyspace_misses\":10,\"memory_peak_bytes\":2097152,\"memory_used_bytes\":1048576,\"retained\":true,\"sampled_at\":1794760000,\"stale\":false,\"success\":true,\"uptime_seconds\":3600,\"version\":1}\n"
);
$assert($badMetrics->request('instance.metrics') === null, 'Reject negative metric values.');
$staleMetricResponse = "{\"commands_per_second\":12,\"connected_clients\":3,\"keyspace_hits\":90,\"keyspace_misses\":10,\"memory_peak_bytes\":2097152,\"memory_used_bytes\":1048576,\"retained\":true,\"sampled_at\":1794760000,\"stale\":true,\"success\":true,\"uptime_seconds\":3600,\"version\":1}\n";
$staleMetrics = new BrokerClient(static fn (string $request): string => $staleMetricResponse);
$assert($staleMetrics->request('instance.metrics')['stale'] === true, 'Accept an exact validated stale metrics response.');
$notRetainedStale = new BrokerClient(static fn (string $request): string =>
    str_replace('"retained":true', '"retained":false', $staleMetricResponse)
);
$assert($notRetainedStale->request('instance.metrics') === null, 'Reject a stale response without a retained sample.');
$badStaleMetrics = new BrokerClient(static fn (string $request): string =>
    "{\"commands_per_second\":12,\"connected_clients\":3,\"keyspace_hits\":90,\"keyspace_misses\":10,\"memory_peak_bytes\":2097152,\"memory_used_bytes\":1048576,\"retained\":true,\"sampled_at\":\"1794760000\",\"stale\":1,\"success\":true,\"uptime_seconds\":3600,\"version\":1}\n"
);
$assert($badStaleMetrics->request('instance.metrics') === null, 'Reject malformed timestamp and stale marker types.');
$historyRequests = [];
$historySamples = [
    ['sampled_at' => 1794760000, 'memory_used_bytes' => 1048576, 'connected_clients' => 2, 'keyspace_hits' => 9, 'keyspace_misses' => 1],
    ['sampled_at' => 1794763600, 'memory_used_bytes' => 2097152, 'connected_clients' => 3, 'keyspace_hits' => 19, 'keyspace_misses' => 1],
];
$historyClient = new BrokerClient(static function (string $request) use (&$historyRequests, $historySamples): string {
    $historyRequests[] = $request;
    return json_encode(['history' => $historySamples, 'range' => '24h', 'scheduled' => true, 'success' => true, 'version' => 1], JSON_THROW_ON_ERROR) . "\n";
});
$history = $historyClient->metricsHistory('24h');
$assert($history['history'] === $historySamples && $history['scheduled'] === true,
    'Parse a bounded hourly history response.');
$assert($historyRequests[0] === "{\"operation\":\"metrics.history\",\"range\":\"24h\",\"version\":1}\n",
    'Send the canonical selected history range without account identifiers.');
$assert($historyClient->metricsHistory('30d') === null, 'Reject unsupported history ranges before broker I/O.');
$assert(count($historyRequests) === 1, 'Do not send an invalid history range to the broker.');
$wrongHistoryRange = new BrokerClient(static fn (string $request): string =>
    "{\"history\":[],\"range\":\"7d\",\"scheduled\":true,\"success\":true,\"version\":1}\n"
);
$assert($wrongHistoryRange->metricsHistory('24h') === null, 'Reject a history response for a different requested range.');
$unorderedHistory = new BrokerClient(static fn (string $request): string =>
    json_encode(['history' => [$historySamples[1], $historySamples[0]], 'range' => '24h', 'scheduled' => true, 'success' => true, 'version' => 1], JSON_THROW_ON_ERROR) . "\n"
);
$assert($unorderedHistory->metricsHistory('24h') === null, 'Reject history points that are not strictly time ordered.');
$oversizedHistory = new BrokerClient(static function (string $request): string {
    $samples = array_fill(0, 25, ['sampled_at' => 1794760000, 'memory_used_bytes' => 1, 'connected_clients' => 1, 'keyspace_hits' => 1, 'keyspace_misses' => 1]);
    return json_encode(['history' => $samples, 'range' => '24h', 'scheduled' => true, 'success' => true, 'version' => 1], JSON_THROW_ON_ERROR) . "\n";
});
$assert($oversizedHistory->metricsHistory('24h') === null, 'Reject more hourly samples than the selected range can contain.');
$badHistoryValue = new BrokerClient(static fn (string $request): string =>
    "{\"history\":[{\"sampled_at\":1794760000,\"memory_used_bytes\":-1,\"connected_clients\":1,\"keyspace_hits\":1,\"keyspace_misses\":1}],\"range\":\"24h\",\"scheduled\":true,\"success\":true,\"version\":1}\n"
);
$assert($badHistoryValue->metricsHistory('24h') === null, 'Reject negative hourly history values.');
$backupId = 'snapshot-1794760000-a1b2c3d4.rdb';
$backupRow = ['created_at' => 1794760000, 'id' => $backupId, 'size_bytes' => 4096];
$backupRequests = [];
$backupClient = new BrokerClient(static function (string $request) use (&$backupRequests, $backupRow): string {
    $backupRequests[] = $request;
    if (str_contains($request, 'backup.create')) {
        return json_encode(['backup' => $backupRow, 'success' => true, 'version' => 1], JSON_THROW_ON_ERROR) . "\n";
    }
    return json_encode(['backups' => [$backupRow], 'success' => true, 'version' => 1], JSON_THROW_ON_ERROR) . "\n";
});
$assert($backupClient->request('backup.list')['backups'] === [$backupRow], 'Parse a validated account backup listing.');
$assert($backupRequests[0] === "{\"operation\":\"backup.list\",\"version\":1}\n", 'Backup list requests contain no account identity or paths.');
$assert($backupClient->request('backup.create')['backup'] === $backupRow, 'Parse a validated created backup receipt.');
$assert($backupRequests[1] === "{\"operation\":\"backup.create\",\"version\":1}\n", 'Backup create requests contain no account identity or paths.');
$restoreRequests = [];
$restoreClient = new BrokerClient(static function (string $request) use (&$restoreRequests, $backupId): string {
    $restoreRequests[] = $request;
    return json_encode([
        'backup_id' => $backupId,
        'safety_backup_id' => 'snapshot-1794760001-b2c3d4e5.rdb',
        'state' => 'running',
        'success' => true,
        'version' => 1,
    ], JSON_THROW_ON_ERROR) . "\n";
});
$restored = $restoreClient->restoreBackup($backupId);
$assert($restoreRequests[0] === "{\"backup_id\":\"{$backupId}\",\"operation\":\"backup.restore\",\"version\":1}\n",
    'Restore requests contain only the selected opaque snapshot identifier.');
$assert($restored === [
    'backup_id' => $backupId,
    'safety_backup_id' => 'snapshot-1794760001-b2c3d4e5.rdb',
    'state' => 'running',
    'success' => true,
    'version' => 1,
], 'Parse a restore receipt only when the selected snapshot and service state match.');
$assert($restoreClient->restoreBackup('../other.rdb') === null,
    'Reject path-like snapshot values before broker I/O.');
$assert(count($restoreRequests) === 1, 'Do not send an invalid restore identifier to the broker.');
$mismatchedRestore = new BrokerClient(static fn (string $request): string =>
    "{\"backup_id\":\"snapshot-1794760000-a1b2c3d4.rdb\",\"safety_backup_id\":\"snapshot-1794760001-b2c3d4e5.rdb\",\"state\":\"running\",\"success\":true,\"version\":1}\n"
);
$assert($mismatchedRestore->restoreBackup('snapshot-1794760002-c3d4e5f6.rdb') === null,
    'Reject a success receipt for a different selected snapshot.');
$malformedRestoreSafety = new BrokerClient(static fn (string $request): string =>
    "{\"backup_id\":\"snapshot-1794760002-c3d4e5f6.rdb\",\"safety_backup_id\":\"../other.rdb\",\"state\":\"running\",\"success\":true,\"version\":1}\n"
);
$assert($malformedRestoreSafety->restoreBackup('snapshot-1794760002-c3d4e5f6.rdb') === null,
    'Reject an unsafe safety snapshot identifier.');
$restoreFailure = new BrokerClient(static fn (string $request): string =>
    "{\"error\":\"restore_failed\",\"safety_backup_id\":\"snapshot-1794760001-b2c3d4e5.rdb\",\"success\":false,\"version\":1}\n"
);
$assert($restoreFailure->restoreBackup($backupId) === [
    'success' => false,
    'error' => 'restore_failed',
    'safety_backup_id' => 'snapshot-1794760001-b2c3d4e5.rdb',
    'version' => 1,
], 'Preserve the safety snapshot ID in a validated restore failure.');
$malformedBackup = new BrokerClient(static fn (string $request): string =>
    "{\"backups\":[{\"created_at\":1794760000,\"id\":\"../other.rdb\",\"size_bytes\":4096}],\"success\":true,\"version\":1}\n"
);
$assert($malformedBackup->request('backup.list') === null, 'Reject unsafe backup identifiers from the broker.');
$oversizedBackup = new BrokerClient(static fn (string $request): string =>
    "{\"backup\":{\"created_at\":1794760000,\"id\":\"snapshot-1794760000-a1b2c3d4.rdb\",\"size_bytes\":134217729},\"success\":true,\"version\":1}\n"
);
$assert($oversizedBackup->request('backup.create') === null, 'Reject snapshots above the transfer size cap.');
$badBackupOrder = new BrokerClient(static fn (string $request): string =>
    "{\"backups\":[{\"created_at\":1794760000,\"id\":\"snapshot-1794760000-a1b2c3d4.rdb\",\"size_bytes\":4096},{\"created_at\":1794760001,\"id\":\"snapshot-1794760001-a1b2c3d4.rdb\",\"size_bytes\":4096}],\"success\":true,\"version\":1}\n"
);
$assert($badBackupOrder->request('backup.list') === null, 'Reject a backup list that is not newest-first.');
$backupFailure = new BrokerClient(static fn (string $request): string =>
    "{\"error\":\"backup_failed\",\"success\":false,\"version\":1}\n"
);
$assert($backupFailure->request('backup.create') === ['success' => false, 'error' => 'backup_failed', 'version' => 1],
    'Parse a generic failed snapshot transfer without exposing command output.');
$before = count($requests);
$assert($client->request('instance.delete') === null, 'Reject unrecognized operations.');
$assert(count($requests) === $before, 'Do not send an unrecognized operation to the broker.');

$failed = new BrokerClient(static fn (string $request): string =>
    "{\"error\":\"backend_policy_required\",\"success\":false,\"version\":1}\n"
);
$assert($failed->request('instance.provision') === [
    'success' => false,
    'error' => 'backend_policy_required',
    'version' => 1,
], 'Parse a known failure response.');

$configurationUnavailable = new BrokerClient(static fn (string $request): string =>
    "{\"error\":\"configuration_unavailable\",\"success\":false,\"version\":1}\n"
);
$assert($configurationUnavailable->request('instance.configure', null, $config) === [
    'success' => false,
    'error' => 'configuration_unavailable',
    'version' => 1,
], 'Parse a failure when current runtime settings cannot be read.');

$extraField = new BrokerClient(static fn (string $request): string =>
    "{\"success\":true,\"state\":\"running\",\"version\":1,\"username\":\"other\"}\n"
);
$assert($extraField->request('instance.status') === null, 'Reject unexpected response fields.');

$multiFrame = new BrokerClient(static fn (string $request): string =>
    "{\"success\":true,\"state\":\"running\",\"version\":1}\n{}\n"
);
$assert($multiFrame->request('instance.status') === null, 'Reject multiple response frames.');

$fleetRequests = [];
$fleet = new BrokerClient(static function (string $request) use (&$fleetRequests): string {
    $fleetRequests[] = $request;
    return "{\"entries\":[{\"state\":\"running\",\"username\":\"demo\"}],\"offset\":30,\"success\":true,\"total\":31,\"version\":1}\n";
});
$fleetPage = $fleet->requestFleetPage(30);
$assert($fleetRequests[0] === "{\"offset\":30,\"operation\":\"fleet.list\",\"version\":1}\n",
    'Send only the fixed fleet operation and bounded offset.');
$assert($fleetPage['total'] === 31 && $fleetPage['entries'][0]['username'] === 'demo',
    'Parse an account-scoped fleet page.');
$assert($fleet->requestFleetPage(-1) === null, 'Reject negative fleet offsets before sending.');

$badFleet = new BrokerClient(static fn (string $request): string =>
    "{\"entries\":[{\"state\":\"running\",\"username\":\"../root\"}],\"offset\":0,\"success\":true,\"total\":1,\"version\":1}\n"
);
$assert($badFleet->requestFleetPage(0) === null, 'Reject unsafe account names in fleet responses.');

$controlRequests = [];
$controlClient = new BrokerClient(static function (string $request) use (&$controlRequests): string {
    $controlRequests[] = $request;
    return "{\"action\":\"restart\",\"audit_logged\":true,\"state\":\"starting\",\"success\":true,\"username\":\"demo\",\"version\":1}\n";
});
$controlResult = $controlClient->controlFleetAccount('demo', 'restart');
$assert($controlRequests[0] === "{\"action\":\"restart\",\"operation\":\"fleet.control\",\"username\":\"demo\",\"version\":1}\n",
    'Send only a fixed fleet control action and validated target name.');
$assert($controlResult === ['action' => 'restart', 'audit_logged' => true, 'state' => 'starting', 'success' => true, 'username' => 'demo', 'version' => 1],
    'Parse a normalized transitional service state for a fleet action.');
$assert($controlClient->controlFleetAccount('../root', 'restart') === null
    && $controlClient->controlFleetAccount('demo', 'CONFIG') === null,
    'Reject unsafe target names and actions before broker I/O.');
$assert(count($controlRequests) === 1, 'Do not send malformed fleet action requests.');
$mismatchedControl = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"stop\",\"state\":\"stopped\",\"success\":true,\"username\":\"other\",\"version\":1}\n"
);
$assert($mismatchedControl->controlFleetAccount('demo', 'stop') === null,
    'Reject fleet action receipts for a different action or account.');
$controlWithoutAudit = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"start\",\"audit_logged\":false,\"state\":\"starting\",\"success\":true,\"username\":\"demo\",\"version\":1}\n"
);
$assert($controlWithoutAudit->controlFleetAccount('demo', 'start')['audit_logged'] === false,
    'Keep an unconfirmed audit status separate from a successful service request.');
$controlFailure = new BrokerClient(static fn (string $request): string =>
    "{\"audit_logged\":true,\"error\":\"not_configured\",\"success\":false,\"version\":1}\n"
);
$assert($controlFailure->controlFleetAccount('demo', 'start') === [
    'success' => false, 'error' => 'not_configured', 'version' => 1, 'audit_logged' => true,
], 'Parse a fixed safe fleet action failure.');

fwrite(STDOUT, "cPanel broker client checks passed: {$checks}\n");
