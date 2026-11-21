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
$authStatusRequests = [];
$authStatusClient = new BrokerClient(static function (string $request) use (&$authStatusRequests): string {
    $authStatusRequests[] = $request;
    return "{\"auth_configured\":false,\"success\":true,\"version\":1}\n";
});
$assert($authStatusClient->authStatus() === [
    'auth_configured' => false, 'success' => true, 'version' => 1,
], 'Read a masked boolean AUTH state without returning credential material.');
$assert($authStatusRequests[0] === "{\"operation\":\"instance.auth.status\",\"version\":1}\n",
    'AUTH status requests contain no secret or caller-selected account.');
$authDisableRequests = [];
$authDisableClient = new BrokerClient(static function (string $request) use (&$authDisableRequests): string {
    $authDisableRequests[] = $request;
    return "{\"auth_configured\":false,\"success\":true,\"version\":1}\n";
});
$assert($authDisableClient->disableAuth() === [
    'auth_configured' => false, 'success' => true, 'version' => 1,
], 'Accept the canonical AUTH disable response without a secret.');
$assert($authDisableRequests[0] === "{\"operation\":\"instance.auth.disable\",\"version\":1}\n",
    'Send only the canonical AUTH disable operation.');
$rotationSecret = str_repeat('A', 43);
$rotationRequests = [];
$rotationClient = new BrokerClient(static function (string $request) use (&$rotationRequests, $rotationSecret): string {
    $rotationRequests[] = $request;
    return json_encode([
        'auth_configured' => true, 'secret' => $rotationSecret, 'success' => true, 'version' => 1,
    ], JSON_THROW_ON_ERROR) . "\n";
});
$rotation = $rotationClient->rotateAuth();
$assert($rotation === [
    'auth_configured' => true, 'secret' => $rotationSecret, 'success' => true, 'version' => 1,
], 'Accept a bounded generated credential only from the explicit rotation response.');
$assert($rotationRequests[0] === "{\"operation\":\"instance.auth.rotate\",\"version\":1}\n"
    && !str_contains($rotationRequests[0], $rotationSecret), 'Never send plaintext credentials in rotation requests.');
$badRotation = new BrokerClient(static fn (string $request): string =>
    "{\"auth_configured\":true,\"secret\":\"bad secret\",\"success\":true,\"version\":1}\n"
);
$assert($badRotation->rotateAuth() === null, 'Reject malformed generated credential values.');
$badDisable = new BrokerClient(static fn (string $request): string =>
    "{\"auth_configured\":true,\"success\":true,\"version\":1}\n"
);
$assert($badDisable->disableAuth() === null, 'Reject a success response that leaves AUTH enabled.');
$extraAuthStatus = new BrokerClient(static fn (string $request): string =>
    "{\"auth_configured\":false,\"secret\":\"leaked\",\"success\":true,\"version\":1}\n"
);
$assert($extraAuthStatus->authStatus() === null, 'Reject secret fields from the AUTH status response.');
$exposureRequests = [];
$exposureClient = new BrokerClient(static function (string $request) use (&$exposureRequests): string {
    $exposureRequests[] = $request;
    return "{\"exposure\":\"developer\",\"success\":true,\"version\":1}\n";
});
$assert($exposureClient->request('provider.exposure') === [
    'exposure' => 'developer', 'success' => true, 'version' => 1,
], 'Accept only the fixed provider exposure tier response.');
$assert($exposureRequests[0] === "{\"operation\":\"provider.exposure\",\"version\":1}\n",
    'Exposure queries contain no account or reseller identity.');
$badExposure = new BrokerClient(static fn (string $request): string =>
    "{\"exposure\":\"secret\",\"success\":true,\"version\":1}\n"
);
$assert($badExposure->request('provider.exposure') === null, 'Reject an unknown exposure enum.');
$eventStatusRequests = [];
$eventStatusClient = new BrokerClient(static function (string $request) use (&$eventStatusRequests): string {
    $eventStatusRequests[] = $request;
    return "{\"destination\":\"https://hooks.example.net/orm\",\"enabled\":false,\"key_configured\":true,\"success\":true,\"version\":1}\n";
});
$assert($eventStatusClient->providerEventStatus() === [
    'destination' => 'https://hooks.example.net/orm', 'enabled' => false,
    'key_configured' => true, 'success' => true, 'version' => 1,
], 'Read provider event settings without reading a signing key.');
$assert($eventStatusRequests[0] === "{\"operation\":\"provider.events.status\",\"version\":1}\n",
    'Provider event status sends only the fixed read operation.');
$eventConfigureRequests = [];
$eventConfigureClient = new BrokerClient(static function (string $request) use (&$eventConfigureRequests): string {
    $eventConfigureRequests[] = $request;
    return "{\"destination\":\"https://hooks.example.net/orm\",\"enabled\":true,\"key_configured\":true,\"key_rotated\":true,\"success\":true,\"version\":1}\n";
});
$assert($eventConfigureClient->configureProviderEvents('https://hooks.example.net/orm', true, true) === [
    'destination' => 'https://hooks.example.net/orm', 'enabled' => true,
    'key_configured' => true, 'key_rotated' => true, 'success' => true, 'version' => 1,
], 'Accept only bounded provider event configuration state.');
$assert($eventConfigureRequests[0] === "{\"destination\":\"https://hooks.example.net/orm\",\"enabled\":true,\"operation\":\"provider.events.configure\",\"rotate_key\":true,\"version\":1}\n",
    'Provider event configuration sends destination and state but no key material.');
$backendEventRequests = [];
$backendEventClient = new BrokerClient(static function (string $request) use (&$backendEventRequests): string {
    $backendEventRequests[] = $request;
    return "{\"queued\":true,\"success\":true,\"version\":1}\n";
});
$assert($backendEventClient->providerBackendSelected('valkey') === [
    'queued' => true, 'success' => true, 'version' => 1,
], 'Accept a bounded backend-selected event result.');
$assert($backendEventRequests[0] === "{\"backend\":\"valkey\",\"operation\":\"provider.backend.selected\",\"version\":1}\n",
    'Backend telemetry sends only the fixed backend enum.');
$unsafeBackendEventRequests = [];
$unsafeBackendEventClient = new BrokerClient(static function (string $request) use (&$unsafeBackendEventRequests): string {
    $unsafeBackendEventRequests[] = $request;
    return "{\"queued\":true,\"success\":true,\"version\":1}\n";
});
$assert($unsafeBackendEventClient->providerBackendSelected('other') === null
    && count($unsafeBackendEventRequests) === 0, 'Reject unlisted backends before broker I/O.');
$eventQueueClient = new BrokerClient(static fn (string $request): string =>
    "{\"counts\":{\"delivered\":1,\"expired\":0,\"failed\":0,\"pending\":1,\"sending\":0},\"records\":[{\"age_seconds\":30,\"attempts\":1,\"next_attempt_at\":1795220030,\"outcome\":\"retryable\",\"state\":\"pending\"}],\"success\":true,\"version\":1}\n"
);
$queueSummary = $eventQueueClient->providerEventQueueStatus();
$assert(is_array($queueSummary) && $queueSummary['counts']['pending'] === 1
    && $queueSummary['records'][0]['outcome'] === 'retryable', 'Read normalized event queue status without IDs or payloads.');
$badEventStatus = new BrokerClient(static fn (string $request): string =>
    "{\"destination\":\"\",\"enabled\":false,\"key\":\"leaked\",\"key_configured\":true,\"success\":true,\"version\":1}\n"
);
$assert($badEventStatus->providerEventStatus() === null, 'Reject a signing key field from event status.');
$unsafeEventConfigRequests = [];
$unsafeEventConfigClient = new BrokerClient(static function (string $request) use (&$unsafeEventConfigRequests): string {
    $unsafeEventConfigRequests[] = $request;
    return "{\"error\":\"invalid_request\",\"success\":false,\"version\":1}\n";
});
$assert($unsafeEventConfigClient->configureProviderEvents('https://hooks.example.net/?secret=x', true, false) === null
    && count($unsafeEventConfigRequests) === 0, 'Reject destination query strings before broker I/O.');
$branding = [
    'product_name' => 'Northstar Cache',
    'logo_png_base64' => base64_encode(file_get_contents(dirname(__DIR__) . '/packaging/whm/icons/orm-whm.png')),
    'support_url' => 'https://support.example.com/redis',
    'preset' => 'orm',
    'primary_color' => '#C92319',
    'secondary_color' => '#A91F18',
    'surface_color' => '#FFFFFF',
    'text_color' => '#172536',
    'footer_visible' => true,
];
$brandingRequests = [];
$brandingClient = new BrokerClient(static function (string $request) use (&$brandingRequests, $branding): string {
    $brandingRequests[] = $request;
    return json_encode(['branding' => $branding, 'success' => true, 'version' => 1], JSON_THROW_ON_ERROR) . "\n";
});
$assert($brandingClient->request('provider.branding') === [
    'branding' => $branding, 'success' => true, 'version' => 1,
], 'Accept validated provider branding fields and a bounded PNG.');
$brokenBranding = $branding;
$brokenBranding['logo_png_base64'] = base64_encode("\x89PNG\r\n\x1a\n" . pack('N', 13) . 'IHDR' . pack('N2', 16, 16));
$brokenBrandingClient = new BrokerClient(static fn (string $request): string =>
    json_encode(['branding' => $brokenBranding, 'success' => true, 'version' => 1], JSON_THROW_ON_ERROR) . "\n"
);
$assert($brokenBrandingClient->request('provider.branding') === null,
    'Reject truncated PNG data from the broker response.');
$assert($brandingRequests[0] === "{\"operation\":\"provider.branding\",\"version\":1}\n",
    'Branding queries contain no account or reseller identity.');
$badBranding = $branding;
$badBranding['primary_color'] = '#FFFFFF';
$badBrandingClient = new BrokerClient(static fn (string $request): string =>
    json_encode(['branding' => $badBranding, 'success' => true, 'version' => 1], JSON_THROW_ON_ERROR) . "\n"
);
$assert($badBrandingClient->request('provider.branding') === null,
    'Reject provider branding whose color fails contrast validation.');
$badBranding['primary_color'] = '#C92319';
$badBranding['logo_png_base64'] = base64_encode('<svg xmlns="http://www.w3.org/2000/svg"/>');
$unsafeLogoBrandingClient = new BrokerClient(static fn (string $request): string =>
    json_encode(['branding' => $badBranding, 'success' => true, 'version' => 1], JSON_THROW_ON_ERROR) . "\n"
);
$assert($unsafeLogoBrandingClient->request('provider.branding') === null,
    'Reject active SVG data from the broker branding response.');
$summaryRow = [
    'owner' => 'reseller1', 'account_count' => 2, 'active_instances' => 1, 'memory_mib' => 48,
    'max_instances' => 5, 'max_memory_mib' => 128,
];
$resellerClient = new BrokerClient(static fn (string $request): string =>
    "{\"resellers\":[{\"account_count\":2,\"active_instances\":1,\"max_instances\":5,\"max_memory_mib\":128,\"memory_mib\":48,\"owner\":\"reseller1\"}],\"success\":true,\"version\":1}\n"
);
$resellerSummary = $resellerClient->request('provider.resellers');
$assert(($resellerSummary['resellers'][0] ?? null) === $summaryRow,
    'Parse a bounded root-side reseller usage summary.');
$unsafeResellerSummary = new BrokerClient(static fn (string $request): string =>
    "{\"resellers\":[{\"account_count\":2,\"active_instances\":1,\"max_instances\":5,\"max_memory_mib\":128,\"memory_mib\":48,\"owner\":\"../root\"}],\"success\":true,\"version\":1}\n"
);
$assert($unsafeResellerSummary->request('provider.resellers') === null,
    'Reject unsafe owner names from the root-only reseller summary.');
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
$reportOnlyProvision = new BrokerClient(static fn (string $request): string =>
    "{\"config\":{\"maxclients\":100,\"maxmemory_policy\":\"allkeys-lru\",\"memory_mib\":64,\"timeout\":0},\"policy_warnings\":[\"memory_limit_exceeded\"],\"preset\":\"generic\",\"state\":\"running\",\"success\":true,\"version\":1}\n"
);
$reportOnlyResult = $reportOnlyProvision->request('instance.provision', 'generic');
$assert($reportOnlyResult['policy_warnings'] === ['memory_limit_exceeded'],
    'Expose only allowlisted report-only package policy warnings to the account UI.');
$clientLimitWarning = new BrokerClient(static fn (string $request): string =>
    "{\"config\":{\"maxclients\":50,\"maxmemory_policy\":\"allkeys-lru\",\"memory_mib\":48,\"timeout\":60},\"policy_warnings\":[\"client_limit_exceeded\"],\"preset\":\"generic\",\"state\":\"running\",\"success\":true,\"version\":1}\n"
);
$assert($clientLimitWarning->request('instance.configure', null, [
    'memory_mib' => 48, 'maxmemory_policy' => 'allkeys-lru', 'maxclients' => 50, 'timeout' => 60,
])['policy_warnings'] === ['client_limit_exceeded'],
    'Expose the fixed client ceiling warning without returning provider policy values.');
$unexpectedPolicyWarning = new BrokerClient(static fn (string $request): string =>
    "{\"config\":{\"maxclients\":100,\"maxmemory_policy\":\"allkeys-lru\",\"memory_mib\":64,\"timeout\":0},\"policy_warnings\":[\"private detail\"],\"preset\":\"generic\",\"state\":\"running\",\"success\":true,\"version\":1}\n"
);
$assert($unexpectedPolicyWarning->request('instance.provision', 'generic') === null,
    'Reject arbitrary provider warning text from the broker.');
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
$reportOnlyConfigure = new BrokerClient(static fn (string $request): string =>
    "{\"config\":{\"maxclients\":50,\"maxmemory_policy\":\"allkeys-lru\",\"memory_mib\":48,\"timeout\":60},\"policy_warnings\":[\"memory_limit_exceeded\"],\"preset\":\"generic\",\"state\":\"running\",\"success\":true,\"version\":1}\n"
);
$configuredWithWarning = $reportOnlyConfigure->request('instance.configure', null, $config);
$assert(($configuredWithWarning['policy_warnings'] ?? null) === ['memory_limit_exceeded'],
    'Expose allowlisted report-only package warnings after a configuration change.');
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
$providerPolicyDenied = new BrokerClient(static fn (string $request): string =>
    "{\"error\":\"provider_policy_denied\",\"success\":false,\"version\":1}\n"
);
$assert($providerPolicyDenied->request('instance.provision', 'generic') === [
    'success' => false,
    'error' => 'provider_policy_denied',
    'version' => 1,
], 'Parse a provider policy denial without leaking rule details.');

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
$fleetUsage = '"usage":{"connected_clients":3,"client_limit":100,"memory_limit_bytes":67108864,"memory_used_bytes":1048576,"sampled_at":1794760000,"state":"fresh"}';
$fleet = new BrokerClient(static function (string $request) use (&$fleetRequests, $fleetUsage): string {
    $fleetRequests[] = $request;
    return "{\"entries\":[{\"backend\":\"redis\",\"backups\":[],\"backups_available\":true,\"state\":\"running\",\"username\":\"demo\"," . $fleetUsage . "}],\"offset\":30,\"success\":true,\"total\":31,\"version\":1}\n";
});
$fleetPage = $fleet->requestFleetPage(30);
$assert($fleetRequests[0] === "{\"offset\":30,\"operation\":\"fleet.list\",\"version\":1}\n",
    'Send only the fixed fleet operation and bounded offset.');
$assert($fleetPage['total'] === 31 && $fleetPage['entries'][0]['username'] === 'demo'
    && $fleetPage['entries'][0]['usage']['memory_used_bytes'] === 1048576,
    'Parse an account-scoped fleet page and validated usage snapshot.');
$assert($fleet->requestFleetPage(-1) === null, 'Reject negative fleet offsets before sending.');

$badFleet = new BrokerClient(static fn (string $request): string =>
    "{\"entries\":[{\"backend\":\"redis\",\"backups\":[],\"backups_available\":true,\"state\":\"running\",\"username\":\"../root\"}],\"offset\":0,\"success\":true,\"total\":1,\"version\":1}\n"
);
$assert($badFleet->requestFleetPage(0) === null, 'Reject unsafe account names in fleet responses.');
$malformedFleetBackups = new BrokerClient(static fn (string $request): string =>
    "{\"entries\":[{\"backend\":\"redis\",\"backups\":[{\"created_at\":1794760000,\"id\":\"../x.rdb\",\"size_bytes\":4096}],\"backups_available\":true,\"state\":\"running\",\"username\":\"demo\"," . $fleetUsage . "}],\"offset\":0,\"success\":true,\"total\":1,\"version\":1}\n"
);
$assert($malformedFleetBackups->requestFleetPage(0) === null, 'Reject unsafe snapshot metadata in fleet responses.');
$malformedFleetUsage = new BrokerClient(static fn (string $request): string =>
    "{\"entries\":[{\"backend\":\"redis\",\"backups\":[],\"backups_available\":true,\"state\":\"running\",\"username\":\"demo\",\"usage\":{\"connected_clients\":0,\"client_limit\":100,\"memory_limit_bytes\":67108864,\"memory_used_bytes\":0,\"sampled_at\":null,\"state\":\"unknown\"}}],\"offset\":0,\"success\":true,\"total\":1,\"version\":1}\n"
);
$assert($malformedFleetUsage->requestFleetPage(0) === null, 'Reject unknown usage responses that turn missing measurements into zero.');

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

$diagnosticRequests = [];
$diagnosticPayloads = [
    'ping' => ['response' => 'PONG'],
    'info_server' => ['server_version' => '7.2.4', 'uptime_seconds' => 3600],
    'info_memory' => ['memory_used_bytes' => 1048576, 'memory_peak_bytes' => 2097152, 'maxmemory_bytes' => 67108864],
    'info_clients' => ['connected_clients' => 3, 'blocked_clients' => 0, 'maxclients' => 100],
    'info_stats' => ['commands_per_second' => 12, 'keyspace_hits' => 90, 'keyspace_misses' => 10, 'expired_keys' => 4, 'evicted_keys' => 2],
    'dbsize' => ['database_keys' => 42],
];
$diagnosticClient = new BrokerClient(static function (string $request) use (&$diagnosticRequests, $diagnosticPayloads): string {
    $diagnosticRequests[] = $request;
    $commandClass = json_decode($request, true, 4, JSON_THROW_ON_ERROR)['command_class'];
    return json_encode([
        'action' => 'diagnostics.' . $commandClass, 'audit_logged' => true,
        'command_class' => $commandClass, 'result' => $diagnosticPayloads[$commandClass],
        'state' => 'running', 'success' => true, 'username' => 'demo', 'version' => 1,
    ], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
});
$assert(($diagnosticClient->diagnoseFleetAccount('demo', 'dbsize')['result']['database_keys'] ?? null) === 42,
    'Parse a normalized fixed diagnostics response.');
foreach (['ping', 'info_server', 'info_memory', 'info_clients', 'info_stats', 'dbsize'] as $commandClass) {
    $diagnosticResult = $diagnosticClient->diagnoseFleetAccount('demo', $commandClass);
    $lastRequest = end($diagnosticRequests);
    $assert(($diagnosticResult['success'] ?? false) && $diagnosticResult['command_class'] === $commandClass
        && $lastRequest === "{\"command_class\":\"{$commandClass}\",\"operation\":\"fleet.diagnostics\",\"username\":\"demo\",\"version\":1}\n",
        "Send only and validate the fixed {$commandClass} command class.");
}
$requestCountBeforeInvalid = count($diagnosticRequests);
$assert($diagnosticClient->diagnoseFleetAccount('../root', 'ping') === null
    && $diagnosticClient->diagnoseFleetAccount('demo', 'flushall') === null
    && count($diagnosticRequests) === $requestCountBeforeInvalid,
    'Reject unsafe diagnostics targets before broker I/O.');
$badDiagnosticClient = new BrokerClient(static fn (string $request): string => json_encode([
    'action' => 'diagnostics.dbsize', 'audit_logged' => true, 'command_class' => 'dbsize',
    'result' => ['database_keys' => 42, 'raw_output' => 'private data'],
    'state' => 'running', 'success' => true, 'username' => 'demo', 'version' => 1,
], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
$assert($badDiagnosticClient->diagnoseFleetAccount('demo', 'dbsize') === null,
    'Reject unexpected raw or unbounded fields from diagnostics responses.');
$boundaryDiagnosticClient = new BrokerClient(static fn (string $request): string => json_encode([
    'action' => 'diagnostics.dbsize', 'audit_logged' => true, 'command_class' => 'dbsize',
    'result' => ['database_keys' => 9_000_000_000_000_000],
    'state' => 'running', 'success' => true, 'username' => 'demo', 'version' => 1,
], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
$assert(($boundaryDiagnosticClient->diagnoseFleetAccount('demo', 'dbsize')['result']['database_keys'] ?? null) === 9_000_000_000_000_000,
    'Accept diagnostics counters at the shared numeric response boundary.');
$tooLargeDiagnosticClient = new BrokerClient(static fn (string $request): string => json_encode([
    'action' => 'diagnostics.dbsize', 'audit_logged' => true, 'command_class' => 'dbsize',
    'result' => ['database_keys' => 9_000_000_000_000_001],
    'state' => 'running', 'success' => true, 'username' => 'demo', 'version' => 1,
], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n");
$assert($tooLargeDiagnosticClient->diagnoseFleetAccount('demo', 'dbsize') === null,
    'Reject diagnostics counters above the shared numeric response boundary.');
$recoveryRequests = [];
$recoveryClient = new BrokerClient(static function (string $request) use (&$recoveryRequests): string {
    $recoveryRequests[] = $request;
    return "{\"action\":\"recovery.scan\",\"audit_logged\":true,\"finding\":\"service_stopped\",\"repair\":\"start\",\"state\":\"stopped\",\"success\":true,\"username\":\"demo\",\"version\":1}\n";
});
$recoveryScan = $recoveryClient->scanFleetRecovery('demo');
$assert($recoveryRequests[0] === "{\"operation\":\"fleet.recovery.scan\",\"username\":\"demo\",\"version\":1}\n"
    && ($recoveryScan['finding'] ?? null) === 'service_stopped' && ($recoveryScan['repair'] ?? null) === 'start',
    'Send and parse the exact read-only recovery scan schema.');
$assert($recoveryClient->scanFleetRecovery('../root') === null && count($recoveryRequests) === 1,
    'Reject malformed recovery scan targets before broker I/O.');
$badRecoveryClient = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"recovery.scan\",\"audit_logged\":true,\"finding\":\"service_stopped\",\"raw_output\":\"private\",\"repair\":\"start\",\"state\":\"stopped\",\"success\":true,\"username\":\"demo\",\"version\":1}\n"
);
$assert($badRecoveryClient->scanFleetRecovery('demo') === null,
    'Reject unexpected raw output in recovery scan responses.');
$configRecoveryScanClient = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"recovery.scan\",\"audit_logged\":true,\"finding\":\"config_drift\",\"repair\":\"config_rebuild\",\"state\":\"failed\",\"success\":true,\"username\":\"demo\",\"version\":1}\n"
);
$configRecoveryScan = $configRecoveryScanClient->scanFleetRecovery('demo');
$assert(($configRecoveryScan['finding'] ?? null) === 'config_drift'
    && ($configRecoveryScan['repair'] ?? null) === 'config_rebuild' && ($configRecoveryScan['state'] ?? null) === 'failed',
    'Accept the fixed scan-guided config rebuild finding for a failed instance.');
$invalidConfigRecoveryScanClient = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"recovery.scan\",\"audit_logged\":true,\"finding\":\"config_drift\",\"repair\":null,\"state\":\"not_configured\",\"success\":true,\"username\":\"demo\",\"version\":1}\n"
);
$assert($invalidConfigRecoveryScanClient->scanFleetRecovery('demo') === null,
    'Reject config drift when the service has no verified configured state.');
$runningConfigRecoveryScanClient = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"recovery.scan\",\"audit_logged\":true,\"finding\":\"config_drift\",\"state\":\"running\",\"success\":true,\"username\":\"demo\",\"version\":1}\n"
);
$runningConfigRecoveryScan = $runningConfigRecoveryScanClient->scanFleetRecovery('demo');
$assert(($runningConfigRecoveryScan['repair'] ?? null) === null,
    'Accept a config drift finding without repair when the service is running.');
$repairRequests = [];
$repairClient = new BrokerClient(static function (string $request) use (&$repairRequests): string {
    $repairRequests[] = $request;
    return "{\"action\":\"recovery.start\",\"audit_logged\":true,\"state\":\"starting\",\"success\":true,\"username\":\"demo\",\"version\":1}\n";
});
$repairResult = $repairClient->repairFleetAccount('demo', 'start');
$assert($repairRequests[0] === "{\"operation\":\"fleet.recovery.repair\",\"repair\":\"start\",\"username\":\"demo\",\"version\":1}\n"
    && ($repairResult['state'] ?? null) === 'starting',
    'Send only the fixed start recovery repair.');
$assert($repairClient->repairFleetAccount('demo', 'restart') === null && count($repairRequests) === 1,
    'Reject recovery actions outside the fixed start repair before broker I/O.');
$failedRepairClient = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"recovery.start\",\"audit_logged\":true,\"error\":\"operation_in_progress\",\"success\":false,\"username\":\"demo\",\"version\":1}\n"
);
$assert(($failedRepairClient->repairFleetAccount('demo', 'start')['error'] ?? null) === 'operation_in_progress',
    'Parse a safe in-progress recovery result.');
$removedInstanceRepairClient = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"recovery.start\",\"audit_logged\":true,\"error\":\"not_configured\",\"success\":false,\"username\":\"demo\",\"version\":1}\n"
);
$assert(($removedInstanceRepairClient->repairFleetAccount('demo', 'start')['error'] ?? null) === 'not_configured',
    'Parse a safe result when the instance disappears before the locked repair check.');
$configRebuildRequests = [];
$configRebuildClient = new BrokerClient(static function (string $request) use (&$configRebuildRequests): string {
    $configRebuildRequests[] = $request;
    return "{\"action\":\"recovery.config_rebuild\",\"audit_logged\":true,\"state\":\"stopped\",\"success\":true,\"username\":\"demo\",\"version\":1}\n";
});
$configRebuildResult = $configRebuildClient->repairFleetAccount('demo', 'config_rebuild');
$assert($configRebuildRequests[0] === "{\"operation\":\"fleet.recovery.repair\",\"repair\":\"config_rebuild\",\"username\":\"demo\",\"version\":1}\n"
    && ($configRebuildResult['action'] ?? null) === 'recovery.config_rebuild'
    && ($configRebuildResult['state'] ?? null) === 'stopped',
    'Send and parse only the fixed scan-guided configuration rebuild repair.');
$badConfigRebuildStateClient = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"recovery.config_rebuild\",\"audit_logged\":true,\"state\":\"running\",\"success\":true,\"username\":\"demo\",\"version\":1}\n"
);
$assert($badConfigRebuildStateClient->repairFleetAccount('demo', 'config_rebuild') === null,
    'Reject a configuration rebuild receipt that claims the service was running.');
$controlFailure = new BrokerClient(static fn (string $request): string =>
    "{\"audit_logged\":true,\"error\":\"not_configured\",\"success\":false,\"version\":1}\n"
);
$assert($controlFailure->controlFleetAccount('demo', 'start') === [
    'success' => false, 'error' => 'not_configured', 'version' => 1, 'audit_logged' => true,
], 'Parse a fixed safe fleet action failure.');

$fleetBackupRequests = [];
$fleetBackup = new BrokerClient(static function (string $request) use (&$fleetBackupRequests): string {
    $fleetBackupRequests[] = $request;
    return "{\"action\":\"backup.create\",\"audit_logged\":true,\"backup\":{\"created_at\":1794760000,\"id\":\"snapshot-1794760000-a1b2c3d4.rdb\",\"size_bytes\":4096},\"success\":true,\"username\":\"demo\",\"version\":1}\n";
});
$fleetBackupResult = $fleetBackup->backupFleetAccount('demo', 'create');
$assert($fleetBackupRequests[0] === "{\"operation\":\"fleet.backup.create\",\"username\":\"demo\",\"version\":1}\n",
    'Send a canonical fleet backup request with only the validated account.');
$assert(($fleetBackupResult['success'] ?? false) && $fleetBackupResult['backup']['id'] === 'snapshot-1794760000-a1b2c3d4.rdb',
    'Parse a bounded per-account backup receipt.');
$fleetRestoreRequests = [];
$fleetRestoreClient = new BrokerClient(static function (string $request) use (&$fleetRestoreRequests): string {
    $fleetRestoreRequests[] = $request;
    return "{\"action\":\"backup.restore\",\"audit_logged\":true,\"backup_id\":\"snapshot-1794760000-a1b2c3d4.rdb\",\"safety_backup_id\":\"snapshot-1794760001-b2c3d4e5.rdb\",\"state\":\"running\",\"success\":true,\"username\":\"demo\",\"version\":1}\n";
});
$fleetRestoreResult = $fleetRestoreClient->backupFleetAccount('demo', 'restore', 'snapshot-1794760000-a1b2c3d4.rdb');
$assert(str_contains($fleetRestoreRequests[0], '"operation":"fleet.backup.restore"')
    && ($fleetRestoreResult['success'] ?? false) && $fleetRestoreResult['safety_backup_id'] === 'snapshot-1794760001-b2c3d4e5.rdb',
    'Send and validate a selected account restore with its safety snapshot result.');
$assert($fleetBackup->backupFleetAccount('../root', 'create') === null
    && $fleetBackup->backupFleetAccount('demo', 'restore', '../outside.rdb') === null,
    'Reject unsafe account and snapshot identifiers before broker I/O.');

$migrationRequests = [];
$migrationClient = new BrokerClient(static function (string $request) use (&$migrationRequests): string {
    $migrationRequests[] = $request;
    return "{\"action\":\"migration.to-valkey\",\"audit_logged\":true,\"safety_backup_id\":\"snapshot-1794760000-a1b2c3d4.rdb\",\"source_backend\":\"redis\",\"state\":\"running\",\"success\":true,\"target_backend\":\"valkey\",\"username\":\"demo\",\"version\":1}\n";
});
$migrationResult = $migrationClient->migrateFleetAccount('demo', 'valkey', true);
$assert($migrationRequests[0] === "{\"operation\":\"fleet.migrate\",\"target_backend\":\"valkey\",\"username\":\"demo\",\"version\":1,\"writes_quiesced\":true}\n",
    'Send the fixed Valkey target with a required write-quiescence acknowledgement.');
$assert(($migrationResult['success'] ?? false) && $migrationResult['safety_backup_id'] === 'snapshot-1794760000-a1b2c3d4.rdb',
    'Parse the migration receipt only when the account, backends, state, audit status, and snapshot are valid.');
$assert($migrationClient->migrateFleetAccount('../root', 'valkey', true) === null
    && $migrationClient->migrateFleetAccount('demo', 'redis', true) === null
    && $migrationClient->migrateFleetAccount('demo', 'valkey', false) === null
    && count($migrationRequests) === 1,
    'Reject unsafe migration targets and unconfirmed write downtime before broker I/O.');
$unsafeMigrationReceipt = new BrokerClient(static fn (string $request): string =>
    "{\"action\":\"migration.to-valkey\",\"audit_logged\":true,\"safety_backup_id\":\"../dump.rdb\",\"source_backend\":\"redis\",\"state\":\"running\",\"success\":true,\"target_backend\":\"valkey\",\"username\":\"demo\",\"version\":1}\n"
);
$assert($unsafeMigrationReceipt->migrateFleetAccount('demo', 'valkey', true) === null,
    'Reject a migration receipt containing an unsafe safety snapshot identifier.');

$summaryRequests = [];
$summaryResponse = json_encode([
    'account_count' => 3, 'managed_count' => 2, 'unconfigured_count' => 1, 'unverified_count' => 0,
    'state_counts' => ['failed' => 0, 'running' => 1, 'starting' => 0, 'stopped' => 1, 'stopping' => 0, 'unavailable' => 0],
    'metrics' => ['alert_accounts' => 0, 'connected_clients' => 2, 'fresh_accounts' => 1,
        'high_client_accounts' => 0, 'high_memory_accounts' => 0, 'latest_sampled_at' => 1794760000,
        'low_hit_ratio_accounts' => 0, 'memory_used_bytes' => 8192, 'missing_accounts' => 1, 'stale_accounts' => 0],
    'partial' => true, 'success' => true, 'version' => 1,
], JSON_THROW_ON_ERROR) . "\n";
$summaryClient = new BrokerClient(static function (string $request) use (&$summaryRequests, $summaryResponse): string {
    $summaryRequests[] = $request;
    return $summaryResponse;
});
$summaryResult = $summaryClient->requestFleetSummary();
$assert($summaryRequests[0] === "{\"operation\":\"fleet.summary\",\"version\":1}\n"
    && ($summaryResult['partial'] ?? false) && $summaryResult['metrics']['missing_accounts'] === 1
    && array_key_exists('backend_counts', $summaryResult) && $summaryResult['backend_counts'] === null,
    'Request the root fleet summary, preserve missing data as partial, and normalize legacy broker counts to unavailable.');
$unsafeSummary = new BrokerClient(static fn (string $request): string =>
    str_replace('"partial":true', '"partial":true,"secret":"x"', $summaryResponse));
$assert($unsafeSummary->requestFleetSummary() === null, 'Reject extra fields in the fleet summary response.');
$extendedSummaryPayload = json_decode($summaryResponse, true, 8, JSON_THROW_ON_ERROR);
$extendedSummaryPayload['metrics'] = array_replace($extendedSummaryPayload['metrics'], [
    'eviction_activity_accounts' => 1, 'max_evictions_per_window' => 2,
    'max_operations_per_second' => 5, 'rate_accounts' => 1, 'rate_missing_accounts' => 1,
    'rate_window_earliest_start_at' => 1794756400, 'rate_window_latest_end_at' => 1794760000,
    'rate_window_max_seconds' => 3600, 'rate_window_min_seconds' => 3600,
]);
$extendedSummaryPayload['backend_counts'] = ['redis' => 1, 'valkey' => 1];
$extendedSummaryResponse = json_encode($extendedSummaryPayload, JSON_THROW_ON_ERROR) . "\n";
$extendedSummaryClient = new BrokerClient(static fn (string $request): string => $extendedSummaryResponse);
$extendedSummaryResult = $extendedSummaryClient->requestFleetSummary();
$assert(($extendedSummaryResult['metrics']['rate_accounts'] ?? null) === 1
    && $extendedSummaryResult['metrics']['max_operations_per_second'] === 5
    && $extendedSummaryResult['backend_counts'] === ['redis' => 1, 'valkey' => 1],
    'Parse mixed Redis/Valkey counts and bounded counter-rate aggregates while accepting legacy summaries too.');
$invalidBackendCountsPayload = $extendedSummaryPayload;
$invalidBackendCountsPayload['backend_counts'] = ['redis' => 2, 'valkey' => 1];
$invalidBackendCounts = new BrokerClient(static fn (string $request): string =>
    json_encode($invalidBackendCountsPayload, JSON_THROW_ON_ERROR) . "\n");
$assert($invalidBackendCounts->requestFleetSummary() === null,
    'Reject backend totals that do not equal the verified managed-account count.');
$extraBackendCountsPayload = $extendedSummaryPayload;
$extraBackendCountsPayload['backend_counts']['other'] = 0;
$extraBackendCounts = new BrokerClient(static fn (string $request): string =>
    json_encode($extraBackendCountsPayload, JSON_THROW_ON_ERROR) . "\n");
$assert($extraBackendCounts->requestFleetSummary() === null,
    'Reject unknown backend-count keys.');
$invalidRateSummaryPayload = $extendedSummaryPayload;
$invalidRateSummaryPayload['metrics']['rate_accounts'] = 2;
$invalidRateSummary = new BrokerClient(static fn (string $request): string =>
    json_encode($invalidRateSummaryPayload, JSON_THROW_ON_ERROR) . "\n");
$assert($invalidRateSummary->requestFleetSummary() === null,
    'Reject inconsistent measured and missing counter-rate account counts.');
$authExtendedSummaryPayload = $extendedSummaryPayload;
$authExtendedSummaryPayload['metrics'] = array_replace($authExtendedSummaryPayload['metrics'], [
    'auth_failure_accounts' => 1, 'auth_rate_accounts' => 1, 'auth_rate_missing_accounts' => 1,
    'auth_rate_window_earliest_start_at' => 1794756400, 'auth_rate_window_latest_end_at' => 1794760000,
    'auth_rate_window_max_seconds' => 3600, 'auth_rate_window_min_seconds' => 3600,
    'max_auth_failures_per_window' => 3,
]);
$authExtendedSummaryResponse = json_encode($authExtendedSummaryPayload, JSON_THROW_ON_ERROR) . "\n";
$authExtendedSummaryClient = new BrokerClient(static fn (string $request): string => $authExtendedSummaryResponse);
$authExtendedSummaryResult = $authExtendedSummaryClient->requestFleetSummary();
$assert(($authExtendedSummaryResult['metrics']['auth_rate_accounts'] ?? null) === 1
    && $authExtendedSummaryResult['metrics']['max_auth_failures_per_window'] === 3
    && $authExtendedSummaryResult['partial'] === true,
    'Parse bounded optional authentication-failure evidence while preserving rate-only and legacy broker schemas.');
$invalidAuthSummaryPayload = $authExtendedSummaryPayload;
$invalidAuthSummaryPayload['metrics']['auth_rate_accounts'] = 2;
$invalidAuthSummary = new BrokerClient(static fn (string $request): string =>
    json_encode($invalidAuthSummaryPayload, JSON_THROW_ON_ERROR) . "\n");
$assert($invalidAuthSummary->requestFleetSummary() === null,
    'Reject inconsistent authentication measured and missing account counts.');
$invalidAuthWindowPayload = $authExtendedSummaryPayload;
$invalidAuthWindowPayload['metrics']['auth_rate_window_max_seconds'] = 26 * 60 * 60 + 1;
$invalidAuthWindow = new BrokerClient(static fn (string $request): string =>
    json_encode($invalidAuthWindowPayload, JSON_THROW_ON_ERROR) . "\n");
$assert($invalidAuthWindow->requestFleetSummary() === null,
    'Reject authentication evidence outside the 26-hour counter-window bound.');

$batchCreateRequests = [];
$batchCreateResponse = json_encode([
    'action' => 'backup.create', 'partial' => true, 'requested_count' => 2,
    'results' => [
        ['action' => 'backup.create', 'audit_logged' => true,
            'backup' => ['id' => 'snapshot-1794760000-a1b2c3d4.rdb', 'created_at' => 1794760000, 'size_bytes' => 4096],
            'success' => true, 'username' => 'demo'],
        ['action' => 'backup.create', 'audit_logged' => true, 'error' => 'account_unavailable',
            'success' => false, 'username' => 'demo2'],
    ],
    'succeeded_count' => 1, 'success' => true, 'version' => 1,
], JSON_THROW_ON_ERROR) . "\n";
$batchCreateClient = new BrokerClient(static function (string $request) use (&$batchCreateRequests, $batchCreateResponse): string {
    $batchCreateRequests[] = $request;
    return $batchCreateResponse;
});
$batchCreateResult = $batchCreateClient->backupFleetBatch('create', [
    ['username' => 'demo'], ['username' => 'demo2'],
]);
$assert($batchCreateRequests[0] === "{\"operation\":\"fleet.backup.batch.create\",\"targets\":[\"demo\",\"demo2\"],\"version\":1}\n"
    && ($batchCreateResult['partial'] ?? false) && $batchCreateResult['succeeded_count'] === 1,
    'Send a capped batch snapshot request and validate each account outcome.');
$assert($batchCreateClient->backupFleetBatch('create', [['username' => 'demo'], ['username' => 'demo']]) === null
    && $batchCreateClient->backupFleetBatch('create', [['username' => 'demo'], ['username' => 'demo2'], ['username' => 'demo3']]) === null
    && count($batchCreateRequests) === 1,
    'Reject duplicate or over-limit batch selections before broker I/O.');

$batchRestoreResponse = json_encode([
    'action' => 'backup.restore', 'partial' => false, 'requested_count' => 1,
    'results' => [[
        'action' => 'backup.restore', 'audit_logged' => true,
        'backup_id' => 'snapshot-1794760000-a1b2c3d4.rdb',
        'safety_backup_id' => 'snapshot-1794760001-b2c3d4e5.rdb', 'state' => 'running',
        'success' => true, 'username' => 'demo',
    ]],
    'succeeded_count' => 1, 'success' => true, 'version' => 1,
], JSON_THROW_ON_ERROR) . "\n";
$batchRestoreRequests = [];
$batchRestoreClient = new BrokerClient(static function (string $request) use (&$batchRestoreRequests, $batchRestoreResponse): string {
    $batchRestoreRequests[] = $request;
    return $batchRestoreResponse;
});
$batchRestoreResult = $batchRestoreClient->backupFleetBatch('restore', [[
    'username' => 'demo', 'backup_id' => 'snapshot-1794760000-a1b2c3d4.rdb',
]]);
$assert($batchRestoreRequests[0] === "{\"operation\":\"fleet.backup.batch.restore\",\"targets\":[{\"backup_id\":\"snapshot-1794760000-a1b2c3d4.rdb\",\"username\":\"demo\"}],\"version\":1}\n"
    && ($batchRestoreResult['results'][0]['safety_backup_id'] ?? null) === 'snapshot-1794760001-b2c3d4e5.rdb',
    'Validate that a batch restore is account-scoped and returns its safety snapshot.');

fwrite(STDOUT, "cPanel broker client checks passed: {$checks}\n");
