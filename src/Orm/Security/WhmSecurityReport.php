<?php
declare(strict_types=1);

namespace Orm\Security;

/** Builds a bounded report from verified fleet aggregates and normalized audit events. */
final class WhmSecurityReport
{
    private const REPORT_INTERVAL_SECONDS = 60;
    private const METRIC_WINDOW_SECONDS = 900;
    private const MAX_RATE_WINDOW_SECONDS = 26 * 60 * 60;
    private const AUTH_EVENT_WINDOW_SECONDS = 86400;

    /** @return array{allowed:bool,retry_after:int} */
    public static function consumeRateLimit(int $now, string $path = '/run/orm/security-report-rate'): array
    {
        if ($now < 1 || !str_starts_with($path, '/') || str_contains($path, "\0")) {
            return ['allowed' => false, 'retry_after' => self::REPORT_INTERVAL_SECONDS];
        }
        $directory = dirname($path);
        $uid = function_exists('posix_geteuid') ? posix_geteuid() : @fileowner(__FILE__);
        $directoryStat = @lstat($directory);
        $directoryReal = @realpath($directory);
        if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
            || !is_int($uid) || $uid < 0 || ($directoryStat['uid'] ?? -1) !== $uid || ($directoryStat['mode'] & 0022) !== 0
            || !is_string($directoryReal) || $directoryReal !== $directory) {
            return ['allowed' => false, 'retry_after' => self::REPORT_INTERVAL_SECONDS];
        }

        $created = false;
        $handle = @fopen($path, 'x+');
        if (is_resource($handle)) {
            $created = true;
        } else {
            $handle = @fopen($path, 'c+');
        }
        if (!is_resource($handle)) {
            return ['allowed' => false, 'retry_after' => self::REPORT_INTERVAL_SECONDS];
        }
        try {
            if ($created && !@chmod($path, 0600)) {
                return ['allowed' => false, 'retry_after' => self::REPORT_INTERVAL_SECONDS];
            }
            $opened = fstat($handle);
            $current = @lstat($path);
            if (!is_array($opened) || !is_array($current) || (($current['mode'] & 0170000) !== 0100000)
                || ($opened['dev'] ?? null) !== ($current['dev'] ?? null)
                || ($opened['ino'] ?? null) !== ($current['ino'] ?? null)
                || ($opened['uid'] ?? -1) !== $uid || ($current['uid'] ?? -1) !== $uid
                || ($opened['nlink'] ?? 0) !== 1 || ($current['nlink'] ?? 0) !== 1
                || (($opened['mode'] ?? 0) & 0077) !== 0 || !@chmod($path, 0600)
                || !@flock($handle, LOCK_EX | LOCK_NB)) {
                return ['allowed' => false, 'retry_after' => self::REPORT_INTERVAL_SECONDS];
            }
            rewind($handle);
            $saved = stream_get_contents($handle, 32);
            $saved = is_string($saved) ? trim($saved) : null;
            if ($saved !== '' && (!is_string($saved) || preg_match('/\A[1-9][0-9]{0,10}\z/', $saved) !== 1)) {
                return ['allowed' => false, 'retry_after' => self::REPORT_INTERVAL_SECONDS];
            }
            $previous = $saved === '' ? 0 : (int) $saved;
            if ($previous > 0 && $now < $previous + self::REPORT_INTERVAL_SECONDS) {
                return ['allowed' => false, 'retry_after' => max(1, $previous + self::REPORT_INTERVAL_SECONDS - $now)];
            }
            $line = (string) $now . "\n";
            if (!rewind($handle) || !ftruncate($handle, 0) || fwrite($handle, $line) !== strlen($line)
                || !fflush($handle)) {
                return ['allowed' => false, 'retry_after' => self::REPORT_INTERVAL_SECONDS];
            }
            return ['allowed' => true, 'retry_after' => 0];
        } finally {
            @flock($handle, LOCK_UN);
            fclose($handle);
        }
    }

    /** @param array<string,mixed>|null $fleet @param array<string,mixed>|null $audit
     *  @return array<string,mixed>
     */
    public static function build(?array $fleet, ?array $audit, int $generatedAt): array
    {
        $metrics = is_array($fleet['metrics'] ?? null) ? $fleet['metrics'] : null;
        $fleetValid = ($fleet['success'] ?? null) === true && is_array($metrics)
            && is_int($metrics['fresh_accounts'] ?? null) && $metrics['fresh_accounts'] >= 0
            && is_int($metrics['high_memory_accounts'] ?? null) && $metrics['high_memory_accounts'] >= 0
            && is_int($metrics['high_client_accounts'] ?? null) && $metrics['high_client_accounts'] >= 0
            && is_int($metrics['low_hit_ratio_accounts'] ?? null) && $metrics['low_hit_ratio_accounts'] >= 0
            && is_int($metrics['latest_sampled_at'] ?? null) && $metrics['latest_sampled_at'] > 0;
        $ratesValid = ($fleet['success'] ?? null) === true && is_array($metrics)
            && is_int($fleet['managed_count'] ?? null)
            && $fleet['managed_count'] >= 0 && $fleet['managed_count'] <= 10000
            && is_int($metrics['rate_accounts'] ?? null) && $metrics['rate_accounts'] >= 0
            && is_int($metrics['rate_missing_accounts'] ?? null) && $metrics['rate_missing_accounts'] >= 0
            && $metrics['rate_accounts'] + $metrics['rate_missing_accounts'] === $fleet['managed_count']
            && is_int($metrics['eviction_activity_accounts'] ?? null) && $metrics['eviction_activity_accounts'] >= 0
            && $metrics['eviction_activity_accounts'] <= $metrics['rate_accounts']
            && is_int($metrics['max_evictions_per_window'] ?? null) && $metrics['max_evictions_per_window'] >= 0
            && $metrics['max_evictions_per_window'] <= 9_000_000_000_000_000
            && is_int($metrics['max_operations_per_second'] ?? null) && $metrics['max_operations_per_second'] >= 0
            && $metrics['max_operations_per_second'] <= 9_000_000_000_000_000
            && is_int($metrics['rate_window_min_seconds'] ?? null) && $metrics['rate_window_min_seconds'] >= 0
            && is_int($metrics['rate_window_max_seconds'] ?? null) && $metrics['rate_window_max_seconds'] >= 0
            && is_int($metrics['rate_window_earliest_start_at'] ?? null) && $metrics['rate_window_earliest_start_at'] >= 0
            && $metrics['rate_window_earliest_start_at'] <= 9_999_999_999
            && is_int($metrics['rate_window_latest_end_at'] ?? null) && $metrics['rate_window_latest_end_at'] >= 0
            && $metrics['rate_window_latest_end_at'] <= 9_999_999_999;
        if ($ratesValid && $metrics['rate_accounts'] === 0) {
            $ratesValid = $metrics['max_evictions_per_window'] === 0
                && $metrics['max_operations_per_second'] === 0
                && $metrics['rate_window_min_seconds'] === 0 && $metrics['rate_window_max_seconds'] === 0
                && $metrics['rate_window_earliest_start_at'] === 0 && $metrics['rate_window_latest_end_at'] === 0
                && $metrics['eviction_activity_accounts'] === 0;
        } elseif ($ratesValid) {
            $ratesValid = $metrics['rate_window_min_seconds'] >= 1
                && $metrics['rate_window_max_seconds'] >= $metrics['rate_window_min_seconds']
                && $metrics['rate_window_max_seconds'] <= self::MAX_RATE_WINDOW_SECONDS
                && $metrics['rate_window_earliest_start_at'] <= $metrics['rate_window_latest_end_at']
                && $metrics['rate_window_latest_end_at'] <= $generatedAt
                && $metrics['rate_window_latest_end_at'] >= $generatedAt - self::MAX_RATE_WINDOW_SECONDS;
        }
        $authRatesValid = $ratesValid
            && is_int($metrics['auth_rate_accounts'] ?? null) && $metrics['auth_rate_accounts'] >= 0
            && is_int($metrics['auth_rate_missing_accounts'] ?? null) && $metrics['auth_rate_missing_accounts'] >= 0
            && $metrics['auth_rate_accounts'] + $metrics['auth_rate_missing_accounts'] === $fleet['managed_count']
            && is_int($metrics['auth_failure_accounts'] ?? null) && $metrics['auth_failure_accounts'] >= 0
            && $metrics['auth_failure_accounts'] <= $metrics['auth_rate_accounts']
            && is_int($metrics['max_auth_failures_per_window'] ?? null) && $metrics['max_auth_failures_per_window'] >= 0
            && $metrics['max_auth_failures_per_window'] <= 9_000_000_000_000_000
            && is_int($metrics['auth_rate_window_min_seconds'] ?? null) && $metrics['auth_rate_window_min_seconds'] >= 0
            && is_int($metrics['auth_rate_window_max_seconds'] ?? null) && $metrics['auth_rate_window_max_seconds'] >= 0
            && is_int($metrics['auth_rate_window_earliest_start_at'] ?? null)
            && $metrics['auth_rate_window_earliest_start_at'] >= 0
            && $metrics['auth_rate_window_earliest_start_at'] <= 9_999_999_999
            && is_int($metrics['auth_rate_window_latest_end_at'] ?? null)
            && $metrics['auth_rate_window_latest_end_at'] >= 0
            && $metrics['auth_rate_window_latest_end_at'] <= 9_999_999_999;
        if ($authRatesValid && $metrics['auth_rate_accounts'] === 0) {
            $authRatesValid = $metrics['max_auth_failures_per_window'] === 0
                && $metrics['auth_rate_window_min_seconds'] === 0
                && $metrics['auth_rate_window_max_seconds'] === 0
                && $metrics['auth_rate_window_earliest_start_at'] === 0
                && $metrics['auth_rate_window_latest_end_at'] === 0
                && $metrics['auth_failure_accounts'] === 0;
        } elseif ($authRatesValid) {
            $authRatesValid = $metrics['auth_rate_window_min_seconds'] >= 1
                && $metrics['auth_rate_window_max_seconds'] >= $metrics['auth_rate_window_min_seconds']
                && $metrics['auth_rate_window_max_seconds'] <= self::MAX_RATE_WINDOW_SECONDS
                && $metrics['auth_rate_window_earliest_start_at'] <= $metrics['auth_rate_window_latest_end_at']
                && $metrics['auth_rate_window_latest_end_at'] <= $generatedAt
                && $metrics['auth_rate_window_latest_end_at'] >= $generatedAt - self::MAX_RATE_WINDOW_SECONDS;
        }
        $auditValid = ($audit['success'] ?? null) === true && is_array($audit['records'] ?? null)
            && is_bool($audit['partial'] ?? null) && is_array($audit['sources'] ?? null);
        $partial = !$fleetValid || !$ratesValid || !$authRatesValid || !$auditValid || ($fleet['partial'] ?? true) !== false
            || ($audit['partial'] ?? true) !== false || ($ratesValid && $metrics['rate_missing_accounts'] > 0);
        $partial = $partial || ($authRatesValid && $metrics['auth_rate_missing_accounts'] > 0);
        $findings = [];

        if ($fleetValid) {
            $sampledAt = $metrics['latest_sampled_at'];
            self::appendMetricFinding($findings, 'memory_pressure', $metrics['high_memory_accounts'], 'warning',
                'At least 85% of the configured memory ceiling', $sampledAt,
                'Review memory growth and eviction behavior. Ask the provider about the package ceiling before increasing the limit.');
            self::appendMetricFinding($findings, 'client_pressure', $metrics['high_client_accounts'], 'warning',
                'At least 85% of the configured client ceiling', $sampledAt,
                'Review application connection pooling. Ask the provider before increasing the client ceiling.');
            self::appendMetricFinding($findings, 'low_hit_ratio', $metrics['low_hit_ratio_accounts'], 'review',
                'Cumulative hit ratio below 50% after at least 100 key lookups', $sampledAt,
                'Review cache-key reuse and workload behavior; the cumulative ratio resets when Redis restarts.');
        } else {
            $findings[] = self::finding('metrics_unavailable', 'unknown', null,
                'Fleet metrics could not be verified.', 'No metric thresholds were evaluated.');
        }

        if ($ratesValid && $metrics['rate_accounts'] > 0) {
            $windowStart = gmdate('Y-m-d\TH:i:s\Z', $metrics['rate_window_earliest_start_at']);
            $windowEnd = gmdate('Y-m-d\TH:i:s\Z', $metrics['rate_window_latest_end_at']);
            $coverage = $metrics['rate_accounts'] . ' of ' . $fleet['managed_count']
                . ' managed accounts have valid counter windows; ' . $metrics['rate_missing_accounts'] . ' are unknown.';
            $window = ' Individual intervals were ' . $metrics['rate_window_min_seconds'] . '–'
                . $metrics['rate_window_max_seconds'] . ' seconds, spanning ' . $windowStart . ' through ' . $windowEnd . '.';
            $findings[] = self::finding('eviction_rate', 'info', $metrics['eviction_activity_accounts'],
                $coverage . ' ' . $metrics['eviction_activity_accounts'] . ' accounts recorded evictions; the largest per-account delta was '
                . $metrics['max_evictions_per_window'] . '.' . $window,
                'Review eviction policy and cache capacity when evictions are unexpected.',
                gmdate('Y-m-d\TH:i:s\Z', $metrics['rate_window_latest_end_at']));
            $findings[] = self::finding('operation_rate', 'info', $metrics['rate_accounts'],
                $coverage . ' The maximum observed average was ' . $metrics['max_operations_per_second']
                . ' operations per second.' . $window . ' This is descriptive load evidence, not an abuse verdict.',
                'Compare measured rates and timing with the expected application workload; no abuse threshold is configured.',
                gmdate('Y-m-d\TH:i:s\Z', $metrics['rate_window_latest_end_at']));
        } else {
            $findings[] = self::finding('eviction_rate', 'unknown', null,
                'Eviction counter deltas are unavailable for a bounded sample window.',
                'Wait for two compatible samples or review whether counters reset or collection gaps exceed 26 hours.');
            $findings[] = self::finding('operation_rate', 'unknown', null,
                'Operation counter deltas are unavailable for a bounded sample window.',
                'Wait for two compatible samples or review whether counters reset or collection gaps exceed 26 hours.');
        }

        if ($authRatesValid && $metrics['auth_rate_accounts'] > 0) {
            $authWindowStart = gmdate('Y-m-d\\TH:i:s\\Z', $metrics['auth_rate_window_earliest_start_at']);
            $authWindowEnd = gmdate('Y-m-d\\TH:i:s\\Z', $metrics['auth_rate_window_latest_end_at']);
            $authCoverage = $metrics['auth_rate_accounts'] . ' of ' . $fleet['managed_count']
                . ' managed accounts expose valid authentication-failure counter windows; '
                . $metrics['auth_rate_missing_accounts'] . ' are unknown.';
            $findings[] = self::finding('client_authentication_failures', 'info', $metrics['auth_failure_accounts'],
                $authCoverage . ' ' . $metrics['auth_failure_accounts'] . ' accounts recorded one or more failures; '
                . 'the largest per-account counter delta was ' . $metrics['max_auth_failures_per_window']
                . '. These aggregate backend counters do not identify clients or distinguish mistakes from attacks. '
                . 'Individual intervals were ' . $metrics['auth_rate_window_min_seconds'] . '–'
                . $metrics['auth_rate_window_max_seconds'] . ' seconds, spanning ' . $authWindowStart
                . ' through ' . $authWindowEnd . '.' ,
                'Review application credentials and expected connection behavior; no abuse threshold is configured.',
                gmdate('Y-m-d\\TH:i:s\\Z', $metrics['auth_rate_window_latest_end_at']));
        } else {
            $findings[] = self::finding('client_authentication_failures', 'unknown', null,
                'Backend authentication-failure counter deltas are unavailable for a bounded sample window.',
                'This signal depends on an optional INFO counter. Wait for two compatible samples; missing fields, resets, and gaps over 26 hours remain unknown.');
        }

        if ($auditValid && ($audit['partial'] ?? true) === false) {
            $authEvents = 0;
            $authFailures = 0;
            $windowStart = max(0, $generatedAt - self::AUTH_EVENT_WINDOW_SECONDS);
            foreach ($audit['records'] as $event) {
                if (!is_array($event) || !in_array($event['action'] ?? null, ['auth.enable', 'auth.rotate', 'auth.disable'], true)
                    || !is_string($event['timestamp_utc'] ?? null)) {
                    continue;
                }
                $timestamp = strtotime($event['timestamp_utc']);
                if ($timestamp === false || $timestamp < $windowStart || $timestamp > $generatedAt) {
                    continue;
                }
                ++$authEvents;
                if (($event['result'] ?? null) !== 'success') {
                    ++$authFailures;
                }
            }
            if ($authEvents > 0) {
                $findings[] = self::finding('auth_management_events', 'info', $authEvents,
                    $authFailures . ' unsuccessful ORM AUTH management operations in the last 24 hours. These are not Redis client login attempts.',
                    'Review the normalized ORM audit log for the fixed operation outcome. Password values and client authentication attempts are not inspected.');
            }
        } else {
            $findings[] = self::finding('auth_audit_unavailable', 'unknown', null,
                'Authentication management events are unavailable or audit coverage is partial.',
                'Check host journal retention and the WHM audit source status before interpreting this report.');
        }

        $unmeasured = [
            'credential_strength' => 'Weak or reused passwords are not inspected.',
        ];
        return [
            'generated_at_utc' => gmdate('Y-m-d\TH:i:s\Z', max(0, $generatedAt)),
            'mode' => 'report-only',
            'metric_window_seconds' => self::METRIC_WINDOW_SECONDS,
            'max_rate_window_seconds' => self::MAX_RATE_WINDOW_SECONDS,
            'auth_event_window_seconds' => self::AUTH_EVENT_WINDOW_SECONDS,
            'partial' => $partial,
            'findings' => $findings,
            'unmeasured' => $unmeasured,
        ];
    }

    /** @param list<array<string,mixed>> $findings */
    private static function appendMetricFinding(array &$findings, string $category, int $count, string $severity,
        string $evidence, int $sampledAt, string $recommendation): void
    {
        if ($count > 0) {
            $findings[] = self::finding($category, $severity, $count, $evidence,
                $recommendation, gmdate('Y-m-d\TH:i:s\Z', $sampledAt));
        }
    }

    /** @return array<string,mixed> */
    private static function finding(string $category, string $severity, ?int $count, string $evidence,
        string $recommendation, ?string $sampledAt = null): array
    {
        return [
            'category' => $category,
            'count' => $count,
            'evidence' => $evidence,
            'recommendation' => $recommendation,
            'sampled_at_utc' => $sampledAt,
            'severity' => $severity,
        ];
    }
}
