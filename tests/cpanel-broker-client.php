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
$metricResponse = "{\"commands_per_second\":12,\"connected_clients\":3,\"keyspace_hits\":90,\"keyspace_misses\":10,\"memory_peak_bytes\":2097152,\"memory_used_bytes\":1048576,\"success\":true,\"uptime_seconds\":3600,\"version\":1}\n";
$metricsClient = new BrokerClient(static function (string $request) use (&$requests, $metricResponse): string {
    $requests[] = $request;
    return $metricResponse;
});
$metrics = $metricsClient->request('instance.metrics');
$assert($metrics['memory_used_bytes'] === 1048576 && $metrics['keyspace_hits'] === 90,
    'Parse the exact bounded metrics response.');
$assert($requests[2] === "{\"operation\":\"instance.metrics\",\"version\":1}\n",
    'Metrics requests contain no account identity or target path.');
$badMetrics = new BrokerClient(static fn (string $request): string =>
    "{\"commands_per_second\":-1,\"connected_clients\":3,\"keyspace_hits\":90,\"keyspace_misses\":10,\"memory_peak_bytes\":2097152,\"memory_used_bytes\":1048576,\"success\":true,\"uptime_seconds\":3600,\"version\":1}\n"
);
$assert($badMetrics->request('instance.metrics') === null, 'Reject negative metric values.');
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
