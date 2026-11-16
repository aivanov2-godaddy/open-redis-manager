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
    'summary' => ['add' => 1, 'replace' => 2, 'unchanged' => 3, 'move' => 0, 'conflict' => 0, 'retire' => 0],
    'fileActions' => [
        ['action' => 'replace'],
        ['action' => 'add'],
        ['action' => 'unchanged'],
    ],
];
$request = ['confirm_update' => '1', 'candidate_version' => '0.2.0', 'artifact_sha256' => str_repeat('a', 64)];
$assert(ReleaseApplyJob::previewIsConflictFree($preview), 'a verified preview with only supported file actions is applicable');
$assert(ReleaseApplyJob::submissionMatchesPreview($request, $preview), 'explicit confirmation binds to candidate version and artifact digest');
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
$incomplete = $preview;
unset($incomplete['summary']['unchanged']);
$assert(!ReleaseApplyJob::previewIsConflictFree($incomplete), 'an incomplete file summary is rejected');

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
    $capturedArgv = null;
    $launchRunner = static function (array $argv, array $environment) use (&$capturedArgv): array {
        $capturedArgv = $argv;
        return ['exit_code' => 0, 'stdout' => ''];
    };
    $queued = ReleaseApplyJob::submit('root', $session, $request, $preview, $launchRunner);
    $assert(($queued['ok'] ?? false) === true, 'a confirmed preview creates an asynchronous job record');
    $assert(is_array($capturedArgv) && in_array('--no-block', $capturedArgv, true)
        && in_array('--collect', $capturedArgv, true)
        && end($capturedArgv) === $queued['jobId'], 'the launcher receives fixed transient-unit arguments and only the opaque job ID');
    $jobFile = '/var/cpanel/orm/updates/jobs/' . $queued['jobId'] . '.json';
    $stored = json_decode((string) file_get_contents($jobFile), true);
    $assert(ReleaseApplyJob::normalizeRecord($stored, $queued['jobId']) !== null
        && $stored['state'] === 'queued' && $stored['artifactSha256'] === str_repeat('a', 64),
        'the durable queue record binds the accepted release identity');

    $secondLaunchCalled = false;
    $second = ReleaseApplyJob::submit('root', $session, $request, $preview,
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
