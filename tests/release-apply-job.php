<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Security/SessionRequestGuard.php';
require dirname(__DIR__) . '/src/Orm/Update/ReleaseApplyJob.php';

use Orm\Update\ReleaseApplyJob;

$assertions = 0;
$assert = static function (bool $condition, string $message) use (&$assertions): void {
    ++$assertions;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$preview = [
    'ok' => true,
    'installedVersion' => '0.1.0-dev',
    'candidateVersion' => '0.2.0',
    'release' => ['artifactSha256' => str_repeat('a', 64)],
    'summary' => ['add' => 1, 'adopt' => 1, 'normalize' => 0, 'replace' => 2, 'unchanged' => 3, 'move' => 0, 'conflict' => 0, 'retire' => 0],
    'fileActions' => [
        ['key' => 'whm_cgi', 'action' => 'replace', 'target' => '/usr/local/cpanel/whostmgr/docroot/cgi/addon_open_redis_manager.php'],
        ['key' => 'cpanel_icon', 'action' => 'add', 'target' => '/usr/local/cpanel/whostmgr/docroot/addon_plugins/orm-whm.png'],
        ['key' => 'application_asset', 'action' => 'adopt', 'target' => '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/ApplicationDiscovery.php', 'requiresReview' => true],
        ['key' => 'theme_css', 'action' => 'unchanged', 'target' => '/usr/local/cpanel/base/frontend/jupiter/orm/index.live.php'],
    ],
];
$request = ['confirm_update' => '1', 'candidate_version' => '0.2.0', 'artifact_sha256' => str_repeat('a', 64)];
$assert(ReleaseApplyJob::previewIsConflictFree($preview), 'a verified preview with only supported file actions is applicable');
$assert(ReleaseApplyJob::submissionMatchesPreview($request, $preview), 'explicit confirmation binds to candidate version, digest, and reviewed adopt action');
$mismatch = $request;
$mismatch['confirm_update'] = '0';
$assert(!ReleaseApplyJob::submissionMatchesPreview($mismatch, $preview), 'missing explicit confirmation is rejected');
$mismatch = $request;
$mismatch['artifact_sha256'] = str_repeat('b', 64);
$assert(!ReleaseApplyJob::submissionMatchesPreview($mismatch, $preview), 'a mismatched artifact digest is rejected');
$mismatch = $request;
$mismatch['candidate_version'] = '0.3.0';
$assert(!ReleaseApplyJob::submissionMatchesPreview($mismatch, $preview), 'a mismatched candidate version is rejected');

foreach ([['move', 1], ['conflict', 1], ['retire', 1]] as [$field, $value]) {
    $blocked = $preview;
    $blocked['summary'][$field] = $value;
    $assert(!ReleaseApplyJob::previewIsConflictFree($blocked), "a preview with {$field} actions is rejected");
}
$unsupported = $preview;
$unsupported['fileActions'][0]['action'] = 'replace_and_execute';
$assert(!ReleaseApplyJob::previewIsConflictFree($unsupported), 'an unknown file action is rejected');
$unreviewedAdopt = $preview;
$unreviewedAdopt['fileActions'][2]['requiresReview'] = false;
$assert(!ReleaseApplyJob::previewIsConflictFree($unreviewedAdopt), 'an adopt action without operator review is rejected');
$normalize = $preview;
$normalize['summary']['normalize'] = 1;
$normalize['fileActions'][] = ['key' => 'broker_handler', 'action' => 'normalize', 'target' => '/usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/Handler.pm', 'requiresReview' => true];
$assert(ReleaseApplyJob::previewIsConflictFree($normalize), 'a reviewed normalize action can be applied');
$normalize['fileActions'][4]['requiresReview'] = false;
$assert(!ReleaseApplyJob::previewIsConflictFree($normalize), 'a normalize action without operator review is rejected');
$incomplete = $preview;
unset($incomplete['summary']['unchanged']);
$assert(!ReleaseApplyJob::previewIsConflictFree($incomplete), 'an incomplete file summary is rejected');

$maintenancePreview = $preview;
$maintenancePreview['fileActions'][0]['key'] = 'broker_handler';
$assert(ReleaseApplyJob::previewRequiresMaintenance($maintenancePreview), 'changed broker files require a maintenance window');
$maintenancePreview['fileActions'][0]['key'] = 'whm_cgi';
$maintenancePreview['fileActions'][0]['target'] = '/etc/systemd/system/orm-broker.service';
$assert(ReleaseApplyJob::previewRequiresMaintenance($maintenancePreview), 'a service target requires maintenance even when its preview key is not sensitive');
$maintenancePreview['fileActions'][0]['target'] = '/usr/local/cpanel/whostmgr/docroot/cgi/addon_open_redis_manager.php';
$maintenancePreview['fileActions'][0]['key'] = 'instance_unit';
$assert(ReleaseApplyJob::previewRequiresMaintenance($maintenancePreview), 'changed service units require a maintenance window');
$maintenancePreview['fileActions'][0]['key'] = 'broker_handler';
$maintenancePreview['fileActions'][0]['action'] = 'unchanged';
$assert(!ReleaseApplyJob::previewRequiresMaintenance($maintenancePreview), 'unchanged broker files do not require a maintenance window');
$maintenancePreview['fileActions'][0]['action'] = 'adopt';
$maintenancePreview['fileActions'][0]['requiresReview'] = true;
$assert(!ReleaseApplyJob::previewRequiresMaintenance($maintenancePreview), 'exact adopted broker files do not require a maintenance window');
$maintenancePreview['fileActions'][0]['action'] = 'replace';
$maintenancePreview['fileActions'][0]['requiresReview'] = false;
$activePreflight = ReleaseApplyJob::maintenancePreflight($maintenancePreview,
    static fn (array $argv, array $environment): array => ['exit_code' => 0, 'stdout' => "active\n"]);
$assert($activePreflight['required'] && !$activePreflight['ready'] && $activePreflight['state'] === 'active',
    'an active broker blocks a maintenance-required preview');
$inactivePreflight = ReleaseApplyJob::maintenancePreflight($maintenancePreview,
    static fn (array $argv, array $environment): array => ['exit_code' => 3, 'stdout' => "inactive\n"]);
$assert($inactivePreflight['required'] && $inactivePreflight['ready'] && $inactivePreflight['state'] === 'inactive',
    'an inactive broker passes the maintenance preflight');
$unknownPreflight = ReleaseApplyJob::maintenancePreflight($maintenancePreview,
    static fn (array $argv, array $environment): array => ['exit_code' => 4, 'stdout' => "unknown\n"]);
$assert($unknownPreflight['required'] && !$unknownPreflight['ready'] && $unknownPreflight['state'] === 'unavailable',
    'an unverifiable broker state fails closed');
$notRequiredRunnerCalled = false;
$notRequiredPreflight = ReleaseApplyJob::maintenancePreflight($preview,
    static function (array $argv, array $environment) use (&$notRequiredRunnerCalled): array {
        $notRequiredRunnerCalled = true;
        return ['exit_code' => 0, 'stdout' => "active\n"];
    });
$assert(!$notRequiredPreflight['required'] && $notRequiredPreflight['ready'] && !$notRequiredRunnerCalled,
    'a non-maintenance change set does not query or depend on broker state');

$whmPage = file_get_contents(dirname(__DIR__) . '/packaging/whm/cgi/addon_open_redis_manager.php');
$assert(is_string($whmPage)
    && str_contains($whmPage, 'ReleaseApplyJob::maintenancePreflight($updatePreview)'),
    'the WHM preview queries maintenance readiness');
$assert(is_string($whmPage)
    && str_contains($whmPage, 'This change set changes ORM broker or systemd service files and requires a maintenance window.')
    && str_contains($whmPage, 'The update was not queued.'),
    'the WHM page explains the maintenance requirement and fail-closed result');
$assert(is_string($whmPage)
    && str_contains($whmPage, '($updateMaintenancePreflight[\'ready\'] ?? false) === true'),
    'the WHM queue control is conditional on a passing maintenance preflight');
$assert(is_string($whmPage)
    && preg_match('/systemctl[^\n]*(?:stop|restart)[^\n]*orm-broker/i', $whmPage) !== 1,
    'the WHM page never stops or restarts the broker');

$id = str_repeat('c', 32);
$record = [
    'schema' => 'orm-update-job-v1', 'id' => $id, 'state' => 'queued',
    'createdAt' => '2026-11-17T10:00:00Z', 'installedVersion' => '0.1.0-dev',
    'candidateVersion' => '0.2.0', 'artifactSha256' => str_repeat('a', 64),
];
$assert(ReleaseApplyJob::normalizeRecord($record, $id) !== null, 'a valid bounded job record is accepted');
$tampered = $record;
$tampered['actor'] = 'browser';
$assert(ReleaseApplyJob::normalizeRecord($tampered, $id) === null, 'unexpected record fields are rejected');
$tampered = $record;
$tampered['state'] = 'running; touch /tmp/x';
$assert(ReleaseApplyJob::normalizeRecord($tampered, $id) === null, 'unknown job states are rejected');
$tampered = $record;
$tampered['id'] = '../other';
$assert(ReleaseApplyJob::normalizeRecord($tampered, $id) === null, 'job path traversal is rejected');

$runnerCalled = false;
$runner = static function (array $argv, array $environment) use (&$runnerCalled): array {
    $runnerCalled = true;
    return ['exit_code' => 0, 'stdout' => ''];
};
$session = [
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cpsess1234567890/cgi/addon_open_redis_manager.php',
];
$denied = ReleaseApplyJob::submit('reseller', $session, $request, $preview, $runner);
$assert(($denied['ok'] ?? true) === false && !$runnerCalled, 'non-root users cannot launch the update worker');
$statusDenied = ReleaseApplyJob::status('reseller', $session, ['job_id' => $id], $runner);
$assert(($statusDenied['ok'] ?? true) === false && !$runnerCalled, 'non-root users cannot inspect job status');
$badId = ReleaseApplyJob::status('root', $session, ['job_id' => '../etc/passwd'], $runner);
$assert(($badId['ok'] ?? true) === false && !$runnerCalled, 'status rejects malformed IDs before process invocation');
$badRequest = $request;
$badRequest['confirm_update'] = '0';
$notConfirmed = ReleaseApplyJob::submit('root', $session, $badRequest, $preview, $runner);
$assert(($notConfirmed['ok'] ?? true) === false && !$runnerCalled, 'an unconfirmed request cannot reach the queue or systemd launcher');

if (getenv('ORM_TEST_FIXED_QUEUE') === '1') {
    $assert(function_exists('posix_geteuid') && posix_geteuid() === 0, 'fixed-path queue integration runs as root');
    $jobFilesBefore = glob('/var/cpanel/orm/updates/jobs/*.json') ?: [];
    $activeLaunchCalled = false;
    $activeSubmission = ReleaseApplyJob::submit('root', $session, $request, $maintenancePreview = array_replace_recursive(
        $preview,
        ['fileActions' => [['key' => 'broker_handler', 'action' => 'replace']]]
    ), static function (array $argv, array $environment) use (&$activeLaunchCalled): array {
        if (end($argv) === 'orm-broker.service') {
            return ['exit_code' => 0, 'stdout' => "active\n"];
        }
        $activeLaunchCalled = true;
        return ['exit_code' => 0, 'stdout' => ''];
    });
    $jobFilesAfterActiveRefusal = glob('/var/cpanel/orm/updates/jobs/*.json') ?: [];
    $assert(($activeSubmission['ok'] ?? true) === false
        && ($activeSubmission['brokerState'] ?? null) === 'active'
        && !$activeLaunchCalled
        && count($jobFilesAfterActiveRefusal) === count($jobFilesBefore),
        'an active broker is rejected before a job record or systemd-run unit is created');

    $activeSafeProbeCalled = false;
    $activeSafeLaunchCalled = false;
    $activeSafeSubmission = ReleaseApplyJob::submit('root', $session, $request, $preview,
        static function (array $argv, array $environment) use (&$activeSafeProbeCalled, &$activeSafeLaunchCalled): array {
            if (end($argv) === 'orm-broker.service') {
                $activeSafeProbeCalled = true;
                return ['exit_code' => 0, 'stdout' => "active\n"];
            }
            $activeSafeLaunchCalled = true;
            return ['exit_code' => 0, 'stdout' => ''];
        });
    $assert(($activeSafeSubmission['ok'] ?? false) === true
        && !$activeSafeProbeCalled && $activeSafeLaunchCalled,
        'a change set without broker or service files can queue while the broker is active');
    $activeSafeJobFile = '/var/cpanel/orm/updates/jobs/' . ($activeSafeSubmission['jobId'] ?? '') . '.json';
    $assert(preg_match('/\A\/var\/cpanel\/orm\/updates\/jobs\/[a-f0-9]{32}\.json\z/D', $activeSafeJobFile) === 1
        && is_file($activeSafeJobFile) && unlink($activeSafeJobFile),
        'the active-safe queue fixture is removed after it is verified');

    $capturedArgv = null;
    $launchRunner = static function (array $argv, array $environment) use (&$capturedArgv): array {
        if (end($argv) === 'orm-broker.service') {
            return ['exit_code' => 3, 'stdout' => "inactive\n"];
        }
        $capturedArgv = $argv;
        return ['exit_code' => 0, 'stdout' => ''];
    };
    $queued = ReleaseApplyJob::submit('root', $session, $request, $maintenancePreview, $launchRunner);
    $assert(($queued['ok'] ?? false) === true,
        'a confirmed preview creates an asynchronous job record: ' . (string) ($queued['message'] ?? 'unknown queue error'));
    $assert(is_array($capturedArgv) && in_array('--no-block', $capturedArgv, true)
        && in_array('--collect', $capturedArgv, true)
        && end($capturedArgv) === $queued['jobId'], 'the launcher receives fixed transient-unit arguments and only the opaque job ID');
    $jobFile = '/var/cpanel/orm/updates/jobs/' . $queued['jobId'] . '.json';
    $stored = json_decode((string) file_get_contents($jobFile), true);
    $assert(ReleaseApplyJob::normalizeRecord($stored, $queued['jobId']) !== null
        && $stored['state'] === 'queued' && $stored['artifactSha256'] === str_repeat('a', 64),
        'the durable queue record binds the accepted release identity');

    $secondLaunchCalled = false;
    $second = ReleaseApplyJob::submit('root', $session, $request, $maintenancePreview,
        static function (array $argv, array $environment) use (&$secondLaunchCalled): array {
            $secondLaunchCalled = true;
            return ['exit_code' => 0, 'stdout' => ''];
        });
    $assert(($second['ok'] ?? true) === false && ($second['jobId'] ?? null) === $queued['jobId'] && !$secondLaunchCalled,
        'duplicate submissions are blocked and return the existing job ID');

    $status = ReleaseApplyJob::status('root', $session, ['job_id' => $queued['jobId']],
        static fn (array $argv, array $environment): array => ['exit_code' => 0, 'stdout' => '']);
    $assert(($status['ok'] ?? false) === true && $status['state'] === 'queued',
        'status reads a bounded job record while its transient unit is active');
}

fwrite(STDOUT, "Release apply job contract checks passed: {$assertions}\n");
