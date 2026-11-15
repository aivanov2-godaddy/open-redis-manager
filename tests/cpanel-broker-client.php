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

fwrite(STDOUT, "cPanel broker client checks passed: {$checks}\n");
