<?php
declare(strict_types=1);

namespace Orm\Update;

use Orm\Security\SessionRequestGuard;

/** Root-only durable queue and sanitized status API for signed WHM updates. */
final class ReleaseApplyJob
{
    private const STATE_ROOT = '/var/cpanel/orm/updates';
    private const JOB_ROOT = self::STATE_ROOT . '/jobs';
    private const LOCK_PATH = self::JOB_ROOT . '/queue.lock';
    private const WORKER = '/usr/local/cpanel/3rdparty/orm/bin/orm-update-worker.pl';
    private const MAX_RECORD_BYTES = 8192;
    private const MAX_OUTPUT_BYTES = 4096;
    private const MAX_JOB_RECORDS = 100;

    /** @param array<string,mixed> $preview @param array<string,mixed> $request @return array<string,mixed> */
    public static function submit(
        string $authenticatedUser,
        array $server,
        array $request,
        array $preview,
        ?callable $runner = null
    ): array {
        if (!self::authorized($authenticatedUser, $server)) {
            return ['ok' => false, 'message' => 'Only root may start a signed update through the WHM session.'];
        }
        if (!self::submissionMatchesPreview($request, $preview)) {
            return ['ok' => false, 'message' => 'The confirmation does not match a current, conflict-free signed preview. Verify the staged release again.'];
        }
        if (!self::prepareDirectories()) {
            return ['ok' => false, 'message' => 'The protected update job directory is unavailable or unsafe.'];
        }
        if (($runner === null && (!is_file('/usr/bin/timeout') || !is_executable('/usr/bin/timeout')
            || !is_file('/usr/bin/systemd-run') || !is_executable('/usr/bin/systemd-run')
            || !is_file('/usr/bin/perl') || !is_executable('/usr/bin/perl')))
            || !self::protectedFile(self::WORKER)) {
            return ['ok' => false, 'message' => 'This host is missing the installed asynchronous update toolchain.'];
        }

        $lock = self::openQueueLock();
        if (!is_resource($lock)) {
            return ['ok' => false, 'message' => 'The update queue could not be locked safely.'];
        }
        try {
            $jobs = self::listJobs();
            foreach ($jobs as $job) {
                if (($job['state'] ?? null) === 'invalid') {
                    return ['ok' => false, 'message' => 'The update queue contains an invalid or unsafe job record.'];
                }
            }
            if (!self::pruneJobHistory($jobs)) {
                return ['ok' => false, 'message' => 'The protected update history is full of active or recovery-required jobs. Review updater state before queueing another release.'];
            }
            foreach (self::listJobs() as $job) {
                if (($job['state'] ?? null) === 'invalid') {
                    return ['ok' => false, 'message' => 'The update queue contains an invalid or unsafe job record.'];
                }
                if (in_array($job['state'], ['queued', 'running'], true)) {
                    $created = strtotime($job['createdAt']);
                    if (($created === false || time() - $created > 60) && !self::unitIsActive($job['id'], $runner)) {
                        $job['state'] = glob(self::STATE_ROOT . '/transaction.*') !== []
                            ? 'recovery_required' : 'interrupted';
                        $job['finishedAt'] = gmdate('Y-m-d\TH:i:s\Z');
                        self::writeRecord($job['id'], $job);
                    }
                }
                if (in_array($job['state'], ['queued', 'running', 'recovery_required'], true)) {
                    return [
                        'ok' => false,
                        'jobId' => $job['id'],
                        'candidateVersion' => $job['candidateVersion'],
                        'state' => $job['state'],
                        'message' => 'An update job is already active or needs recovery review. Check its status before starting another update.',
                    ];
                }
            }

            try {
                $jobId = bin2hex(random_bytes(16));
            } catch (\Throwable) {
                return ['ok' => false, 'message' => 'A secure update job identifier could not be generated.'];
            }
            $record = [
                'schema' => 'orm-update-job-v1',
                'id' => $jobId,
                'state' => 'queued',
                'createdAt' => gmdate('Y-m-d\TH:i:s\Z'),
                'installedVersion' => $preview['installedVersion'],
                'candidateVersion' => $preview['candidateVersion'],
                'artifactSha256' => $preview['release']['artifactSha256'],
            ];
            if (!self::writeRecord($jobId, $record)) {
                return ['ok' => false, 'message' => 'The update job could not be persisted safely.'];
            }

            $unit = 'orm-release-apply-' . $jobId . '.service';
            $argv = [
                '/usr/bin/timeout', '--signal=KILL', '10s', '/usr/bin/systemd-run',
                '--quiet', '--no-block', '--collect', '--unit=' . $unit,
                '/usr/bin/perl', self::WORKER, $jobId,
            ];
            $environment = [
                'HOME' => '/root',
                'LANG' => 'C',
                'LC_ALL' => 'C',
                'PATH' => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            ];
            $launched = $runner === null ? self::execute($argv, $environment) : $runner($argv, $environment);
            if (!is_array($launched) || !isset($launched['exit_code'], $launched['stdout'])
                || !is_int($launched['exit_code']) || !is_string($launched['stdout'])
                || strlen($launched['stdout']) > self::MAX_OUTPUT_BYTES) {
                self::transitionIfQueued($jobId, 'failed');
                return ['ok' => false, 'jobId' => $jobId, 'message' => 'The update launch could not be confirmed. Check this job status before retrying.'];
            }
            if ($launched['exit_code'] !== 0) {
                self::transitionIfQueued($jobId, 'failed');
                return ['ok' => false, 'jobId' => $jobId, 'message' => 'The update worker launch failed or could not be confirmed. Check this job status before retrying.'];
            }
            return [
                'ok' => true,
                'jobId' => $jobId,
                'candidateVersion' => $record['candidateVersion'],
                'state' => 'queued',
                'message' => 'The signed update was queued. You can check its status from this page.',
            ];
        } finally {
            flock($lock, LOCK_UN);
            fclose($lock);
        }
    }

    /** @param array<string,mixed> $request @return array<string,mixed> */
    public static function status(string $authenticatedUser, array $server, array $request, ?callable $runner = null): array
    {
        if (!self::authorized($authenticatedUser, $server)) {
            return ['ok' => false, 'message' => 'Only root may view signed update status through the WHM session.'];
        }
        $jobId = $request['job_id'] ?? null;
        if (!is_string($jobId) || !preg_match('/\A[a-f0-9]{32}\z/D', $jobId)) {
            return ['ok' => false, 'message' => 'The update job identifier is invalid.'];
        }
        foreach (['/', '/var', '/var/cpanel', '/var/cpanel/orm', self::STATE_ROOT, self::JOB_ROOT] as $directory) {
            $requiredMode = in_array($directory, [self::STATE_ROOT, self::JOB_ROOT], true) ? 0700 : null;
            if (!self::protectedDirectory($directory, $requiredMode)) {
                return ['ok' => false, 'message' => 'The protected update job directory is unavailable or unsafe.'];
            }
        }
        $lock = self::openQueueLock();
        if (!is_resource($lock)) {
            return ['ok' => false, 'message' => 'The update queue could not be locked safely.'];
        }
        try {
            $record = self::readRecord($jobId);
            if ($record === null) {
                return ['ok' => false, 'message' => 'That update job is unavailable.'];
            }
            if (in_array($record['state'], ['queued', 'running'], true)) {
                $created = strtotime($record['createdAt']);
                $age = $created === false ? PHP_INT_MAX : time() - $created;
                if ($age > 60 && !self::unitIsActive($jobId, $runner)) {
                    $hasTransaction = glob(self::STATE_ROOT . '/transaction.*') !== [];
                    $record['state'] = $hasTransaction ? 'recovery_required' : 'interrupted';
                    $record['finishedAt'] = gmdate('Y-m-d\TH:i:s\Z');
                    self::writeRecord($jobId, $record);
                }
            }
            return [
                'ok' => true,
                'jobId' => $record['id'],
                'state' => $record['state'],
                'candidateVersion' => $record['candidateVersion'],
                'createdAt' => $record['createdAt'],
                'startedAt' => $record['startedAt'] ?? null,
                'finishedAt' => $record['finishedAt'] ?? null,
            ];
        } finally {
            flock($lock, LOCK_UN);
            fclose($lock);
        }
    }

    /** @param array<string,mixed> $request @param array<string,mixed> $preview */
    public static function submissionMatchesPreview(array $request, array $preview): bool
    {
        if (($preview['ok'] ?? null) !== true
            || !self::previewIsConflictFree($preview)
            || !in_array($request['confirm_update'] ?? null, ['1', 1, true], true)
            || !is_string($request['candidate_version'] ?? null)
            || strlen($request['candidate_version']) > 128
            || !is_string($request['artifact_sha256'] ?? null)
            || !preg_match('/\A[a-f0-9]{64}\z/D', $request['artifact_sha256'])) {
            return false;
        }
        return hash_equals($preview['candidateVersion'], $request['candidate_version'])
            && hash_equals($preview['release']['artifactSha256'], $request['artifact_sha256']);
    }

    /** @param array<string,mixed> $preview */
    public static function previewIsConflictFree(array $preview): bool
    {
        if (($preview['ok'] ?? null) !== true || !is_array($preview['summary'] ?? null)
            || !is_array($preview['release'] ?? null)
            || !is_string($preview['installedVersion'] ?? null)
            || !is_string($preview['candidateVersion'] ?? null)
            || !self::isVersion($preview['installedVersion'] ?? null)
            || !self::isVersion($preview['candidateVersion'] ?? null)
            || !is_string($preview['release']['artifactSha256'] ?? null)
            || !preg_match('/\A[a-f0-9]{64}\z/D', $preview['release']['artifactSha256'])
            || !is_array($preview['fileActions'] ?? null) || count($preview['fileActions']) > 100) {
            return false;
        }
        foreach (['add', 'adopt', 'replace', 'unchanged', 'move', 'conflict', 'retire'] as $field) {
            if (!is_int($preview['summary'][$field] ?? null) || $preview['summary'][$field] < 0) {
                return false;
            }
        }
        foreach (['move', 'conflict', 'retire'] as $blocked) {
            if (($preview['summary'][$blocked] ?? null) !== 0) {
                return false;
            }
        }
        foreach ($preview['fileActions'] as $action) {
            if (!is_array($action) || !in_array($action['action'] ?? null, ['add', 'adopt', 'replace', 'unchanged'], true)
                || (($action['action'] ?? null) === 'adopt' && ($action['requiresReview'] ?? null) !== true)) {
                return false;
            }
        }
        return true;
    }

    /** @return array<string,mixed>|null */
    public static function normalizeRecord(mixed $record, string $expectedId): ?array
    {
        if (!is_array($record) || array_is_list($record)
            || ($record['schema'] ?? null) !== 'orm-update-job-v1'
            || ($record['id'] ?? null) !== $expectedId
            || !in_array($record['state'] ?? null, ['queued', 'running', 'succeeded', 'failed', 'recovery_required', 'interrupted'], true)
            || !self::isVersion($record['installedVersion'] ?? null)
            || !self::isVersion($record['candidateVersion'] ?? null)
            || !is_string($record['artifactSha256'] ?? null)
            || !preg_match('/\A[a-f0-9]{64}\z/D', $record['artifactSha256'])
            || !self::isTimestamp($record['createdAt'] ?? null)
            || (isset($record['startedAt']) && !self::isTimestamp($record['startedAt']))
            || (isset($record['finishedAt']) && !self::isTimestamp($record['finishedAt']))) {
            return null;
        }
        $allowed = ['schema', 'id', 'state', 'createdAt', 'startedAt', 'finishedAt', 'installedVersion', 'candidateVersion', 'artifactSha256'];
        if (array_diff(array_keys($record), $allowed) !== []) {
            return null;
        }
        return $record;
    }

    private static function authorized(string $user, array $server): bool
    {
        return $user === 'root' && SessionRequestGuard::allowsMutation($server);
    }

    private static function isVersion(mixed $value): bool
    {
        return is_string($value) && preg_match(
            '/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/D',
            $value
        ) === 1;
    }

    private static function isTimestamp(mixed $value): bool
    {
        return is_string($value) && preg_match('/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/D', $value) === 1;
    }

    private static function prepareDirectories(): bool
    {
        $base = '/var/cpanel';
        $orm = '/var/cpanel/orm';
        if (!self::protectedDirectory('/', null) || !self::protectedDirectory('/var', null)
            || !self::protectedDirectory($base, null)) {
            return false;
        }
        if (!file_exists($orm) && !is_link($orm) && !@mkdir($orm, 0711)) {
            return false;
        }
        if (!self::protectedDirectory($orm, null)) {
            return false;
        }
        if (!file_exists(self::STATE_ROOT) && !is_link(self::STATE_ROOT) && !@mkdir(self::STATE_ROOT, 0700)) {
            return false;
        }
        if (!self::protectedDirectory(self::STATE_ROOT, 0700)) {
            return false;
        }
        if (!file_exists(self::JOB_ROOT) && !is_link(self::JOB_ROOT) && !@mkdir(self::JOB_ROOT, 0700)) {
            return false;
        }
        return self::protectedDirectory(self::JOB_ROOT, 0700);
    }

    private static function protectedDirectory(string $path, ?int $exactMode): bool
    {
        $stat = @lstat($path);
        return is_array($stat) && (($stat['mode'] & 0170000) === 0040000)
            && $stat['uid'] === 0 && (($stat['mode'] & 0022) === 0)
            && ($exactMode === null || ($stat['mode'] & 07777) === $exactMode);
    }

    private static function protectedFile(string $path): bool
    {
        $stat = @lstat($path);
        return is_array($stat) && (($stat['mode'] & 0170000) === 0100000)
            && $stat['uid'] === 0 && $stat['nlink'] === 1 && (($stat['mode'] & 0022) === 0);
    }

    /** @return resource|false */
    private static function openQueueLock()
    {
        $existing = @lstat(self::LOCK_PATH);
        if ($existing !== false && (!is_array($existing) || (($existing['mode'] & 0170000) !== 0100000)
            || $existing['uid'] !== 0 || $existing['nlink'] !== 1 || ($existing['mode'] & 0777) !== 0600)) {
            return false;
        }
        $previousUmask = umask(0077);
        $handle = @fopen(self::LOCK_PATH, 'c+b');
        umask($previousUmask);
        if (!is_resource($handle)) {
            return false;
        }
        $opened = fstat($handle);
        $path = @lstat(self::LOCK_PATH);
        if (!is_array($opened) || !is_array($path) || $opened['dev'] !== $path['dev'] || $opened['ino'] !== $path['ino']
            || $path['uid'] !== 0 || $path['nlink'] !== 1 || ($path['mode'] & 0777) !== 0600
            || !flock($handle, LOCK_EX)) {
            fclose($handle);
            return false;
        }
        @chmod(self::LOCK_PATH, 0600);
        return $handle;
    }

    /** @return list<array<string,mixed>> */
    private static function listJobs(): array
    {
        $jobs = [];
        $paths = glob(self::JOB_ROOT . '/*.json') ?: [];
        if (count($paths) > self::MAX_JOB_RECORDS + 1) {
            return [['state' => 'invalid']];
        }
        foreach ($paths as $path) {
            $id = basename($path, '.json');
            if (!preg_match('/\A[a-f0-9]{32}\z/D', $id)) {
                return [['state' => 'invalid']];
            }
            $record = self::readRecord($id);
            if ($record === null) {
                return [['state' => 'invalid']];
            }
            $jobs[] = $record;
        }
        return $jobs;
    }

    /** @param list<array<string,mixed>> $jobs */
    private static function pruneJobHistory(array $jobs): bool
    {
        if (count($jobs) < self::MAX_JOB_RECORDS) {
            return true;
        }
        usort($jobs, static fn (array $left, array $right): int => strcmp($left['createdAt'], $right['createdAt']));
        $remaining = count($jobs);
        foreach ($jobs as $job) {
            if (in_array($job['state'], ['succeeded', 'failed', 'interrupted'], true)) {
                $path = self::JOB_ROOT . '/' . $job['id'] . '.json';
                if (self::readRecord($job['id']) === null || !@unlink($path)) {
                    return false;
                }
                --$remaining;
                if ($remaining < self::MAX_JOB_RECORDS) {
                    return true;
                }
            }
        }
        return $remaining < self::MAX_JOB_RECORDS;
    }

    /** @return array<string,mixed>|null */
    private static function readRecord(string $id): ?array
    {
        $path = self::JOB_ROOT . '/' . $id . '.json';
        $stat = @lstat($path);
        if (!is_array($stat) || (($stat['mode'] & 0170000) !== 0100000) || $stat['uid'] !== 0
            || $stat['nlink'] !== 1 || ($stat['mode'] & 0777) !== 0600 || $stat['size'] > self::MAX_RECORD_BYTES) {
            return null;
        }
        $handle = @fopen($path, 'rb');
        if (!is_resource($handle)) {
            return null;
        }
        $opened = fstat($handle);
        $content = stream_get_contents($handle, self::MAX_RECORD_BYTES + 1);
        fclose($handle);
        if (!is_array($opened) || $opened['dev'] !== $stat['dev'] || $opened['ino'] !== $stat['ino']
            || !is_string($content) || strlen($content) > self::MAX_RECORD_BYTES) {
            return null;
        }
        try {
            $decoded = json_decode($content, true, 8, JSON_THROW_ON_ERROR);
        } catch (\Throwable) {
            return null;
        }
        return self::normalizeRecord($decoded, $id);
    }

    /** @param array<string,mixed> $record */
    private static function writeRecord(string $id, array $record): bool
    {
        if (!preg_match('/\A[a-f0-9]{32}\z/D', $id) || self::normalizeRecord($record, $id) === null) {
            return false;
        }
        $existing = @lstat(self::JOB_ROOT . '/' . $id . '.json');
        if ($existing !== false && (!is_array($existing) || (($existing['mode'] & 0170000) !== 0100000)
            || $existing['uid'] !== 0 || $existing['nlink'] !== 1 || ($existing['mode'] & 0777) !== 0600)) {
            return false;
        }
        try {
            $temporary = self::JOB_ROOT . '/.' . $id . '.' . bin2hex(random_bytes(12)) . '.tmp';
            $handle = @fopen($temporary, 'xb');
            if (!is_resource($handle)) {
                return false;
            }
            $content = json_encode($record, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
            $written = fwrite($handle, $content);
            $flushed = fflush($handle);
            $synced = function_exists('fsync') ? @fsync($handle) : true;
            $opened = fstat($handle);
            fclose($handle);
            if ($written !== strlen($content) || !$flushed || !$synced || !is_array($opened)
                || $opened['uid'] !== 0 || !@chmod($temporary, 0600)) {
                @unlink($temporary);
                return false;
            }
            if (!@rename($temporary, self::JOB_ROOT . '/' . $id . '.json')) {
                @unlink($temporary);
                return false;
            }
            return true;
        } catch (\Throwable) {
            return false;
        }
    }

    private static function transitionIfQueued(string $id, string $state): void
    {
        $record = self::readRecord($id);
        if ($record !== null && $record['state'] === 'queued') {
            $record['state'] = $state;
            $record['finishedAt'] = gmdate('Y-m-d\TH:i:s\Z');
            self::writeRecord($id, $record);
        }
    }

    private static function unitIsActive(string $id, ?callable $runner): bool
    {
        $argv = ['/usr/bin/timeout', '--signal=KILL', '5s', '/usr/bin/systemctl', 'is-active', '--quiet', 'orm-release-apply-' . $id . '.service'];
        $environment = ['HOME' => '/root', 'LANG' => 'C', 'LC_ALL' => 'C', 'PATH' => '/usr/sbin:/usr/bin:/sbin:/bin'];
        $result = $runner === null ? self::execute($argv, $environment) : $runner($argv, $environment);
        return is_array($result) && ($result['exit_code'] ?? null) === 0;
    }

    /** @param list<string> $argv @param array<string,string> $environment @return array{exit_code:int,stdout:string} */
    private static function execute(array $argv, array $environment): array
    {
        $process = @proc_open($argv, [
            0 => ['file', '/dev/null', 'r'],
            1 => ['pipe', 'w'],
            2 => ['file', '/dev/null', 'a'],
        ], $pipes, '/', $environment);
        if (!is_resource($process)) {
            return ['exit_code' => 1, 'stdout' => ''];
        }
        $stdout = stream_get_contents($pipes[1], self::MAX_OUTPUT_BYTES + 1);
        fclose($pipes[1]);
        $status = proc_close($process);
        return ['exit_code' => is_int($status) ? $status : 1, 'stdout' => is_string($stdout) ? $stdout : ''];
    }
}
