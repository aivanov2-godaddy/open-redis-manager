<?php
declare(strict_types=1);

namespace Orm\Security;

/** Reads a bounded set of structured ORM authpriv events and returns normalized fields only. */
final class WhmAuditLog
{
    private const MAX_RANGE_SECONDS = 604800;
    private const MAX_SOURCE_LINES = 1001;
    private const MAX_SOURCE_BYTES = 1048576;
    private const MAX_RECORDS = 1000;
    private const COMMAND_TIMEOUT_SECONDS = 3;
    private const IDENTIFIERS = ['orm-broker', 'orm-whm'];
    private const LIMITATIONS = [
        'Only retained records from the two named ORM journald identifiers are read.',
        'Only recognized fixed-format events are returned; unrecognized rows are counted and omitted.',
        'The viewer does not include cPanel provisioning, configuration, start, or stop operations.',
        'Journal retention, forwarding, and persistence are controlled by the host.',
        'Redis keys, values, passwords, raw log messages, command output, and host paths are not exported.',
    ];
    private const ACTIONS = [
        'start', 'stop', 'restart', 'backup.create', 'backup.restore', 'migration.to-valkey',
        'diagnostics.read', 'recovery.scan', 'recovery.start', 'auth.rotate', 'auth.disable',
        'provider.default', 'provider.package.save', 'provider.package.remove',
        'provider.reseller.save', 'provider.reseller.remove', 'provider.branding.save',
        'backend.select', 'policy.violation', 'security.report',
    ];

    /** @var null|\Closure(string,int,int,int):array{status:string,lines?:list<string>} */
    private ?\Closure $runner;

    /** Test seam accepts captured JSON lines; production uses the fixed journalctl command below. */
    public function __construct(?callable $runner = null)
    {
        $this->runner = $runner === null ? null : \Closure::fromCallable($runner);
    }

    /** @param array{account?:string,action?:string,result?:string} $filters
     *  @return array<string,mixed>
     */
    public function read(int $fromTimestamp, int $toTimestamp, array $filters = []): array
    {
        $normalizedFilters = self::normalizeFilters($filters);
        if ($fromTimestamp < 0 || $toTimestamp < $fromTimestamp
            || ($toTimestamp - $fromTimestamp) >= self::MAX_RANGE_SECONDS
            || $normalizedFilters === null) {
            return ['success' => false, 'error' => 'invalid_filter', 'records' => [], 'sources' => [], 'partial' => true];
        }

        $records = [];
        $sources = [];
        $partial = false;
        foreach (self::IDENTIFIERS as $identifier) {
            $capture = $this->capture($identifier, $fromTimestamp, $toTimestamp);
            $lines = is_array($capture['lines'] ?? null) ? $capture['lines'] : [];
            $truncated = ($capture['status'] ?? null) === 'truncated' || count($lines) >= self::MAX_SOURCE_LINES;
            $unrecognized = 0;
            $parsedCount = 0;
            foreach (array_slice($lines, 0, self::MAX_SOURCE_LINES - 1) as $line) {
                if (!is_string($line)) {
                    ++$unrecognized;
                    continue;
                }
                $journalRow = self::decodeJournalLine($line, $identifier);
                if ($journalRow === null) {
                    ++$unrecognized;
                    continue;
                }
                $event = self::parseEvent($identifier, $journalRow['message']);
                if ($event === null) {
                    ++$unrecognized;
                    continue;
                }
                ++$parsedCount;
                if ($journalRow['timestamp'] < $fromTimestamp || $journalRow['timestamp'] > $toTimestamp
                    || !self::matchesFilters($event, $normalizedFilters)) {
                    continue;
                }
                $records[] = [
                    'timestamp_utc' => gmdate('Y-m-d\TH:i:s\Z', $journalRow['timestamp']),
                    'timestamp' => $journalRow['timestamp'],
                    'source' => $identifier,
                    'actor' => $event['actor'],
                    'account' => $event['account'],
                    'action' => $event['action'],
                    'result' => $event['result'],
                    'state' => $event['state'],
                ];
            }
            $captureStatus = $capture['status'] ?? 'unavailable';
            $sourcePartial = $captureStatus !== 'ok' || $truncated || $unrecognized > 0;
            $partial = $partial || $sourcePartial;
            $sources[] = [
                'identifier' => $identifier,
                'status' => $captureStatus === 'ok' && !$truncated && $unrecognized === 0 ? 'complete'
                    : ($captureStatus === 'ok' ? 'partial' : 'unavailable'),
                'parsed_events' => $parsedCount,
                'unrecognized_rows' => $unrecognized,
                'truncated' => $truncated,
                'reason' => $captureStatus === 'ok' ? null : self::sourceReason($captureStatus),
            ];
        }

        usort($records, static fn (array $left, array $right): int => $right['timestamp'] <=> $left['timestamp']);
        $truncated = count($records) > self::MAX_RECORDS;
        if ($truncated) {
            $records = array_slice($records, 0, self::MAX_RECORDS);
            $partial = true;
        }
        foreach ($records as &$record) {
            unset($record['timestamp']);
        }
        unset($record);

        return [
            'success' => true,
            'generated_at_utc' => gmdate('c'),
            'range' => ['from_utc' => gmdate('c', $fromTimestamp), 'to_utc' => gmdate('c', $toTimestamp)],
            'filters' => $normalizedFilters,
            'record_count' => count($records),
            'records_truncated' => $truncated,
            'partial' => $partial,
            'sources' => $sources,
            'records' => $records,
            'limitations' => self::LIMITATIONS,
        ];
    }

    /** @return array<string,mixed>|null */
    public static function normalizeFilters(array $filters): ?array
    {
        $allowedKeys = ['account', 'action', 'result'];
        foreach (array_keys($filters) as $key) {
            if (!in_array($key, $allowedKeys, true)) {
                return null;
            }
        }
        $account = $filters['account'] ?? '';
        $action = $filters['action'] ?? '';
        $result = $filters['result'] ?? '';
        if (!is_string($account) || ($account !== '' && $account !== 'global'
                && preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $account) !== 1)
            || !is_string($action) || ($action !== '' && !in_array($action, self::ACTIONS, true))
            || !is_string($result) || ($result !== '' && preg_match('/\A[a-z][a-z0-9_-]{0,47}\z/', $result) !== 1)) {
            return null;
        }
        return ['account' => $account, 'action' => $action, 'result' => $result];
    }

    /** @param array<string,mixed> $result */
    public static function toJson(array $result): ?string
    {
        if (($result['success'] ?? null) !== true || !is_array($result['records'] ?? null)
            || !is_array($result['sources'] ?? null) || !is_array($result['range'] ?? null)
            || !is_array($result['filters'] ?? null) || !is_array($result['limitations'] ?? null)
            || !is_string($result['generated_at_utc'] ?? null)
            || preg_match('/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\+00:00|Z)\z/', $result['generated_at_utc']) !== 1
            || !is_bool($result['partial'] ?? null) || !is_bool($result['records_truncated'] ?? null)
            || !is_int($result['record_count'] ?? null) || $result['record_count'] !== count($result['records'])
            || count($result['records']) > self::MAX_RECORDS
            || self::normalizeFilters($result['filters']) !== $result['filters']) {
            return null;
        }
        $range = $result['range'];
        if (!is_string($range['from_utc'] ?? null) || !is_string($range['to_utc'] ?? null)
            || preg_match('/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00\z/', $range['from_utc']) !== 1
            || preg_match('/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00\z/', $range['to_utc']) !== 1) {
            return null;
        }
        $records = [];
        foreach ($result['records'] as $record) {
            if (!is_array($record) || !is_string($record['timestamp_utc'] ?? null)
                || preg_match('/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/', $record['timestamp_utc']) !== 1
                || !in_array($record['source'] ?? null, self::IDENTIFIERS, true)
                || !is_string($record['actor'] ?? null) || preg_match('/\A(?:[0-9]{1,10}|unknown)\z/', $record['actor']) !== 1
                || !is_string($record['account'] ?? null) || preg_match('/\A(?:[a-zA-Z0-9_-]{1,16}|global|invalid)\z/', $record['account']) !== 1
                || !is_string($record['action'] ?? null) || !in_array($record['action'], self::ACTIONS, true)
                || !is_string($record['result'] ?? null) || preg_match('/\A[a-z][a-z0-9_-]{0,47}\z/', $record['result']) !== 1
                || !is_string($record['state'] ?? null) || preg_match('/\A[a-z][a-z0-9_, -]{0,95}\z/', $record['state']) !== 1) {
                return null;
            }
            $records[] = [
                'timestamp_utc' => $record['timestamp_utc'], 'source' => $record['source'],
                'actor' => $record['actor'], 'account' => $record['account'], 'action' => $record['action'],
                'result' => $record['result'], 'state' => $record['state'],
            ];
        }
        $sources = [];
        foreach ($result['sources'] as $source) {
            if (!is_array($source) || !in_array($source['identifier'] ?? null, self::IDENTIFIERS, true)
                || !in_array($source['status'] ?? null, ['complete', 'partial', 'unavailable'], true)
                || !is_int($source['parsed_events'] ?? null) || $source['parsed_events'] < 0
                || !is_int($source['unrecognized_rows'] ?? null) || $source['unrecognized_rows'] < 0
                || !is_bool($source['truncated'] ?? null)
                || !in_array($source['reason'] ?? null, [null, 'journal query timed out', 'journal output reached a safety limit', 'journal source is unavailable'], true)) {
                return null;
            }
            $sources[] = [
                'identifier' => $source['identifier'], 'status' => $source['status'],
                'parsed_events' => $source['parsed_events'], 'unrecognized_rows' => $source['unrecognized_rows'],
                'truncated' => $source['truncated'], 'reason' => $source['reason'],
            ];
        }
        if (count($sources) !== count(self::IDENTIFIERS)
            || array_column($sources, 'identifier') !== self::IDENTIFIERS) {
            return null;
        }
        $export = [
            'schema_version' => 1,
            'generated_at_utc' => $result['generated_at_utc'],
            'range' => ['from_utc' => $range['from_utc'], 'to_utc' => $range['to_utc']],
            'filters' => $result['filters'],
            'record_count' => $result['record_count'],
            'records_truncated' => $result['records_truncated'],
            'partial' => $result['partial'],
            'sources' => $sources,
            'records' => $records,
            'limitations' => self::LIMITATIONS,
        ];
        try {
            return json_encode($export, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
        } catch (\Throwable) {
            return null;
        }
    }

    /** @return array{status:string,lines:list<string>} */
    private function capture(string $identifier, int $fromTimestamp, int $toTimestamp): array
    {
        if ($this->runner !== null) {
            try {
                $result = ($this->runner)($identifier, $fromTimestamp, $toTimestamp, self::MAX_SOURCE_LINES);
            } catch (\Throwable) {
                return ['status' => 'unavailable', 'lines' => []];
            }
            if (!is_array($result) || !in_array($result['status'] ?? null, ['ok', 'unavailable', 'timed_out', 'truncated'], true)
                || !is_array($result['lines'] ?? null) || !array_is_list($result['lines'])) {
                return ['status' => 'unavailable', 'lines' => []];
            }
            return ['status' => $result['status'], 'lines' => array_slice($result['lines'], 0, self::MAX_SOURCE_LINES)];
        }
        return self::runJournalctl($identifier, $fromTimestamp, $toTimestamp);
    }

    /** @return array{status:string,lines:list<string>} */
    private static function runJournalctl(string $identifier, int $fromTimestamp, int $toTimestamp): array
    {
        if (!in_array($identifier, self::IDENTIFIERS, true) || !function_exists('proc_open')
            || !is_executable('/usr/bin/journalctl')) {
            return ['status' => 'unavailable', 'lines' => []];
        }
        $command = [
            '/usr/bin/journalctl', '--quiet', '--no-pager', '--output=json', '--facility=authpriv',
            '--identifier=' . $identifier, '--since=@' . $fromTimestamp, '--until=@' . $toTimestamp,
            '--lines=' . self::MAX_SOURCE_LINES,
        ];
        $pipes = [];
        $process = @proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, ['LANG' => 'C', 'LC_ALL' => 'C']);
        if (!is_resource($process) || count($pipes) !== 3) {
            return ['status' => 'unavailable', 'lines' => []];
        }
        fclose($pipes[0]);
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $stdout = '';
        $status = 'ok';
        $deadline = microtime(true) + self::COMMAND_TIMEOUT_SECONDS;
        $exitCode = null;
        do {
            $processState = proc_get_status($process);
            if (!$processState['running']) {
                $exitCode = $processState['exitcode'];
            }
            $read = [];
            if (!feof($pipes[1])) {
                $read[] = $pipes[1];
            }
            if (!feof($pipes[2])) {
                $read[] = $pipes[2];
            }
            if ($read !== []) {
                $write = null;
                $except = null;
                @stream_select($read, $write, $except, 0, 100000);
                foreach ($read as $stream) {
                    $chunk = fread($stream, 8192);
                    if (!is_string($chunk) || $chunk === '') {
                        continue;
                    }
                    if ($stream === $pipes[1]) {
                        $stdout .= $chunk;
                        if (strlen($stdout) > self::MAX_SOURCE_BYTES) {
                            $status = 'truncated';
                        }
                    }
                }
            }
            if ($status === 'truncated') {
                proc_terminate($process);
                break;
            }
            if (microtime(true) >= $deadline) {
                $status = 'timed_out';
                proc_terminate($process);
                break;
            }
        } while ($processState['running'] || !feof($pipes[1]) || !feof($pipes[2]));
        foreach ([1, 2] as $descriptor) {
            fclose($pipes[$descriptor]);
        }
        $closedCode = proc_close($process);
        if ($status === 'ok' && $exitCode !== 0 && $closedCode !== 0) {
            return ['status' => 'unavailable', 'lines' => []];
        }
        $lines = preg_split('/\r?\n/', trim($stdout), -1, PREG_SPLIT_NO_EMPTY);
        $lines = is_array($lines) ? array_slice($lines, 0, self::MAX_SOURCE_LINES) : [];
        if ($status === 'ok' && count($lines) >= self::MAX_SOURCE_LINES) {
            $status = 'truncated';
        }
        return ['status' => $status, 'lines' => $lines];
    }

    /** @return array{timestamp:int,message:string}|null */
    private static function decodeJournalLine(string $line, string $identifier): ?array
    {
        if (strlen($line) > self::MAX_SOURCE_BYTES) {
            return null;
        }
        try {
            $row = json_decode($line, true, 8, JSON_THROW_ON_ERROR);
        } catch (\Throwable) {
            return null;
        }
        if (!is_array($row) || ($row['SYSLOG_IDENTIFIER'] ?? null) !== $identifier
            || !is_string($row['MESSAGE'] ?? null)
            || !is_string($row['__REALTIME_TIMESTAMP'] ?? null)
            || preg_match('/\A[0-9]{1,20}\z/', $row['__REALTIME_TIMESTAMP']) !== 1) {
            return null;
        }
        $microseconds = (int) $row['__REALTIME_TIMESTAMP'];
        if ($microseconds <= 0) {
            return null;
        }
        return ['timestamp' => intdiv($microseconds, 1_000_000), 'message' => $row['MESSAGE']];
    }

    /** @return array{actor:string,account:string,action:string,result:string,state:string}|null */
    private static function parseEvent(string $identifier, string $message): ?array
    {
        $actor = '(?<actor>(?:[0-9]{1,10}|unknown))';
        $account = '(?<account>(?:[a-zA-Z0-9_-]{1,16}|global|invalid))';
        $action = '(?<action>[a-z][a-z0-9_.-]{0,39})';
        $result = '(?<result>[a-z][a-z0-9_-]{0,47})';
        $state = '(?<state>[a-z][a-z0-9_-]{0,47})';
        if ($identifier === 'orm-broker') {
            $patterns = [
                '/\Afleet_operation actor_uid=' . $actor . ' account=' . $account . ' action=' . $action . ' result=' . $result . ' state=' . $state . '\z/',
                '/\Aaccount_auth actor_uid=' . $actor . ' account=' . $account . ' action=(?<action>auth\.(?:rotate|disable)) result=' . $result . ' state=' . $state . '\z/',
                '/\Abackup_restore actor_uid=' . $actor . ' account=' . $account
                    . ' backup=(?:snapshot-[0-9]{10}-[a-f0-9]{8}\.rdb|invalid) safety=(?:snapshot-[0-9]{10}-[a-f0-9]{8}\.rdb|none) result=' . $result . ' state=' . $state . '\z/',
                '/\Aprovider_policy actor_uid=' . $actor . ' account=' . $account . ' action=(?<action>policy\.violation) result=(?<result>report-only|warn|enforce) state=(?<state>(?:package_disabled|memory_limit_exceeded|reseller_usage_unavailable|reseller_instance_quota_exceeded|reseller_memory_quota_exceeded)(?:,(?:package_disabled|memory_limit_exceeded|reseller_usage_unavailable|reseller_instance_quota_exceeded|reseller_memory_quota_exceeded))*)\z/',
            ];
        } else {
            $patterns = [
                '/\Aprovider_policy actor_uid=0 account=global action=(?<action>provider\.(?:default|package\.save|package\.remove|reseller\.save|reseller\.remove|branding\.save)) result=(?<result>success) state=(?<state>updated)\z/',
                '/\Abackend_policy actor_uid=0 account=global action=(?<action>backend\.select) result=(?<result>success|failure) state=(?<state>redis|valkey|unavailable)\z/',
                '/\Asecurity_report actor_uid=0 account=global action=(?<action>security\.report) result=(?<result>success) state=(?<state>generated)\z/',
            ];
        }
        foreach ($patterns as $pattern) {
            if (preg_match($pattern, $message, $matches) !== 1) {
                continue;
            }
            $event = [
                'actor' => $matches['actor'] ?? '0',
                'account' => $matches['account'] ?? 'global',
                'action' => $matches['action'] ?? '',
                'result' => $matches['result'] ?? '',
                'state' => $matches['state'] ?? '',
            ];
            if (!in_array($event['action'], self::ACTIONS, true)
                || preg_match('/\A[a-z][a-z0-9_-]{0,47}\z/', $event['result']) !== 1
                || preg_match('/\A[a-z][a-z0-9_, -]{0,95}\z/', $event['state']) !== 1) {
                return null;
            }
            return $event;
        }
        return null;
    }

    /** @param array{account:string,action:string,result:string} $filters
     *  @param array{actor:string,account:string,action:string,result:string,state:string} $event
     */
    private static function matchesFilters(array $event, array $filters): bool
    {
        return ($filters['account'] === '' || $event['account'] === $filters['account'])
            && ($filters['action'] === '' || $event['action'] === $filters['action'])
            && ($filters['result'] === '' || $event['result'] === $filters['result']);
    }

    private static function sourceReason(string $status): string
    {
        return match ($status) {
            'timed_out' => 'journal query timed out',
            'truncated' => 'journal output reached a safety limit',
            default => 'journal source is unavailable',
        };
    }
}
