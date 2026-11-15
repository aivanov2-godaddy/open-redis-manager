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

fwrite(STDOUT, "cPanel broker client checks passed: {$checks}\n");
