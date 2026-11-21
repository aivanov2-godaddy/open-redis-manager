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
    public static function build(?array $fleet, ?array $audit, int $generatedAt,
        ?array $securityPolicy = null, bool $policyAvailable = true): array
    {
        $policy = $securityPolicy === null
            ? self::defaultSecurityReportPolicy()
            : WhmSecurityReportPolicyStore::normalize($securityPolicy);
        $policyValid = $policyAvailable && $policy !== null;
        $policy ??= self::defaultSecurityReportPolicy();
        $thresholds = $policy['thresholds'];
        $metrics = is_array($fleet['metrics'] ?? null) ? $fleet['metrics'] : null;
        $podmanMetrics = is_array($fleet['podman_metrics'] ?? null) ? $fleet['podman_metrics'] : null;
        $podmanMetricsValid = self::validPodmanMetrics($podmanMetrics, $generatedAt);
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
        $partial = $partial || ($authRatesValid && $metrics['auth_rate_missing_accounts'] > 0) || !$policyValid
            || !$podmanMetricsValid || ($podmanMetricsValid && $podmanMetrics['partial']);
        $findings = [];

        if (!$policyValid) {
            $findings[] = self::finding('report_policy_unavailable', 'unknown', null,
                'The root-owned security report policy could not be verified; optional abuse thresholds were not evaluated.',
                'Repair or restore the root-owned report policy before relying on threshold-based findings.');
        }

        if (!$podmanMetricsValid) {
            $findings[] = self::finding('podman_metrics_unknown', 'unknown', null,
                'EA Podman Redis/Valkey coverage is unavailable, invalid, or older than 30 minutes; these services were not measured.',
                'Check the scheduled root EA Podman sampler and wait for a fresh, verified snapshot. Unknown containers are excluded from ORM-managed account totals.');
        } else {
            $podmanSampledAt = gmdate('Y-m-d\TH:i:s\Z', $podmanMetrics['sampled_at']);
            $coverageSeverity = $podmanMetrics['partial'] ? 'unknown' : 'info';
            $findings[] = self::finding('podman_metrics_coverage', $coverageSeverity, null,
                $podmanMetrics['discovered_count'] . ' EA Podman containers discovered ('
                    . $podmanMetrics['backend_counts']['redis'] . ' Redis, '
                    . $podmanMetrics['backend_counts']['valkey'] . ' Valkey); '
                    . $podmanMetrics['sampled_count'] . ' were probed, '
                    . $podmanMetrics['reachable_count'] . ' responded, '
                    . $podmanMetrics['unmeasured_count'] . ' could not be measured, and '
                    . $podmanMetrics['skipped_count'] . ' were skipped by scan bounds; '
                    . $podmanMetrics['unverified_account_count'] . ' accounts could not be verified. Podman metrics are separate from ORM-managed accounts.',
                'Treat skipped, unmeasured, or partial Podman coverage as unknown; check the sampler status before drawing fleet-wide conclusions.',
                $podmanSampledAt, $podmanSampledAt, $podmanSampledAt);
        }

        $podmanWindow = $podmanMetricsValid && ($podmanMetrics['counter_window']['status'] ?? null) === 'measured'
            ? $podmanMetrics['counter_window'] : null;
        if ($podmanWindow !== null) {
            $windowStart = gmdate('Y-m-d\\TH:i:s\\Z', $podmanWindow['window_start_at']);
            $windowEnd = gmdate('Y-m-d\\TH:i:s\\Z', $podmanWindow['sampled_at']);
            $windowText = ' Continuity-matched process window: ' . $podmanWindow['window_seconds']
                . ' seconds from ' . $windowStart . ' through ' . $windowEnd . '; '
                . $podmanWindow['process_count'] . ' Redis/Valkey processes matched. Values are maximum per-process observations and do not identify accounts or containers.';
            $evictionThreshold = $thresholds['evictions_per_window'];
            $evictionExceeded = $policyValid && $evictionThreshold > 0
                && $podmanWindow['max_evictions_delta'] >= $evictionThreshold;
            $findings[] = self::finding('podman_eviction_rate', $evictionExceeded ? 'warning' : 'info',
                $podmanWindow['process_count'], 'Maximum per-process eviction delta was '
                . $podmanWindow['max_evictions_delta'] . '.' . $windowText
                . ($evictionThreshold > 0 ? ' Report-only threshold: ' . $evictionThreshold . ' evictions.' : ''),
                'Review eviction policy and cache capacity. This aggregate threshold is advisory and takes no automatic action.',
                $windowEnd, $windowStart, $windowEnd);
            $operationThreshold = $thresholds['operations_per_second'];
            $operationExceeded = $policyValid && $operationThreshold > 0
                && $podmanWindow['max_operations_per_second'] >= $operationThreshold;
            $findings[] = self::finding('podman_operation_rate', $operationExceeded ? 'warning' : 'info',
                $podmanWindow['process_count'], 'Maximum observed per-process average was '
                . $podmanWindow['max_operations_per_second'] . ' operations per second.' . $windowText
                . ' This is descriptive load evidence, not an abuse verdict.'
                . ($operationThreshold > 0 ? ' Report-only threshold: ' . $operationThreshold . ' operations per second.' : ''),
                'Compare measured rates and timing with the expected workload. This advisory threshold takes no automatic action.',
                $windowEnd, $windowStart, $windowEnd);
            if ($podmanWindow['auth_available']) {
                $authThreshold = $thresholds['auth_failures_per_window'];
                $authExceeded = $policyValid && $authThreshold > 0
                    && $podmanWindow['max_auth_failures_delta'] >= $authThreshold;
                $findings[] = self::finding('podman_authentication_failures', $authExceeded ? 'warning' : 'info',
                    $podmanWindow['process_count'], 'Maximum per-process authentication-failure counter delta was '
                    . $podmanWindow['max_auth_failures_delta'] . '.' . $windowText
                    . ($authThreshold > 0 ? ' Report-only threshold: ' . $authThreshold . ' failures.' : ''),
                    'Review authentication configuration and application behavior. This aggregate signal does not identify clients or take automatic action.',
                    $windowEnd, $windowStart, $windowEnd);
            } else {
                $findings[] = self::finding('podman_authentication_failures', 'unknown', null,
                    'At least one continuity-matched process did not provide the optional authentication-failure counter.' . $windowText,
                    'Treat Podman authentication-failure evidence as unknown for this window.');
            }
        } else {
            $podmanCounterEvidence = $podmanMetricsValid
                ? (($podmanMetrics['version'] ?? 1) === 1
                    ? 'The root sampler retains one anonymous aggregate snapshot. It cannot prove the same Redis/Valkey server processes were present in a prior sample, so Podman eviction, operation, and authentication-failure counter windows and thresholds were not evaluated.'
                    : 'A continuity-verified Podman counter window is not available (' . ($podmanMetrics['counter_window']['reason'] ?? 'unknown') . '). Podman counter thresholds were not evaluated.')
                : 'No continuity-verified Podman counter window is available. Podman counter thresholds were not evaluated.';
            $podmanCounterSample = $podmanMetricsValid
                ? gmdate('Y-m-d\\TH:i:s\\Z', $podmanMetrics['sampled_at'])
                : null;
            $findings[] = self::finding('podman_counter_rates_unknown', 'unknown', null,
                $podmanCounterEvidence,
                'Treat Podman counter rates as unknown until two complete samples confirm the same server processes and monotonic counters.',
                $podmanCounterSample);
        }

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
            $evictionThreshold = $thresholds['evictions_per_window'];
            $evictionExceeded = $policyValid && $evictionThreshold > 0
                && $metrics['max_evictions_per_window'] >= $evictionThreshold;
            $findings[] = self::finding('eviction_rate', $evictionExceeded ? 'warning' : 'info', $metrics['eviction_activity_accounts'],
                $coverage . ' ' . $metrics['eviction_activity_accounts'] . ' accounts recorded evictions; the largest per-account delta was '
                . $metrics['max_evictions_per_window'] . '.' . $window
                . ($evictionThreshold > 0 ? ' Report-only threshold: ' . $evictionThreshold . ' evictions per sampled interval.' : ''),
                $evictionExceeded
                    ? 'Review eviction policy and cache capacity. This aggregate threshold is not an abuse verdict and takes no automatic action.'
                    : 'Review eviction policy and cache capacity when evictions are unexpected.',
                gmdate('Y-m-d\TH:i:s\Z', $metrics['rate_window_latest_end_at']), $windowStart, $windowEnd);
            $operationThreshold = $thresholds['operations_per_second'];
            $operationExceeded = $policyValid && $operationThreshold > 0
                && $metrics['max_operations_per_second'] >= $operationThreshold;
            $findings[] = self::finding('operation_rate', $operationExceeded ? 'warning' : 'info', $metrics['rate_accounts'],
                $coverage . ' The maximum observed average was ' . $metrics['max_operations_per_second']
                . ' operations per second.' . $window . ' This is descriptive load evidence, not an abuse verdict.'
                . ($operationThreshold > 0 ? ' Report-only threshold: ' . $operationThreshold . ' operations per second.' : ''),
                $operationExceeded
                    ? 'Compare measured rates and timing with the expected application workload. This threshold is advisory and takes no automatic action.'
                    : 'Compare measured rates and timing with the expected application workload; no operation-rate threshold is configured.',
                gmdate('Y-m-d\TH:i:s\Z', $metrics['rate_window_latest_end_at']), $windowStart, $windowEnd);
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
            $authThreshold = $thresholds['auth_failures_per_window'];
            $authExceeded = $policyValid && $authThreshold > 0
                && $metrics['max_auth_failures_per_window'] >= $authThreshold;
            $findings[] = self::finding('client_authentication_failures', $authExceeded ? 'warning' : 'info', $metrics['auth_failure_accounts'],
                $authCoverage . ' ' . $metrics['auth_failure_accounts'] . ' accounts recorded one or more failures; '
                . 'the largest per-account counter delta was ' . $metrics['max_auth_failures_per_window']
                . '. These aggregate backend counters do not identify clients or distinguish mistakes from attacks. '
                . 'Individual intervals were ' . $metrics['auth_rate_window_min_seconds'] . '–'
                . $metrics['auth_rate_window_max_seconds'] . ' seconds, spanning ' . $authWindowStart
                . ' through ' . $authWindowEnd . '.'
                . ($authThreshold > 0 ? ' Report-only threshold: ' . $authThreshold . ' failures per sampled interval.' : ''),
                $authExceeded
                    ? 'Review application credentials and expected connection behavior. This anonymous aggregate threshold does not identify a client or take automatic action.'
                    : 'Review application credentials and expected connection behavior; no authentication-failure threshold is configured.',
                gmdate('Y-m-d\\TH:i:s\\Z', $metrics['auth_rate_window_latest_end_at']), $authWindowStart, $authWindowEnd);
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
            $eventWindowStart = gmdate('Y-m-d\TH:i:s\Z', $windowStart);
            $eventWindowEnd = gmdate('Y-m-d\TH:i:s\Z', max(0, $generatedAt));
            if ($authEvents > 0) {
                $findings[] = self::finding('auth_management_events', 'info', $authEvents,
                    $authFailures . ' unsuccessful ORM AUTH management operations between ' . $eventWindowStart
                    . ' and ' . $eventWindowEnd . '. These are not Redis client login attempts.',
                    'Review the normalized ORM audit log for the fixed operation outcome. Password values and client authentication attempts are not inspected.',
                    $eventWindowEnd, $eventWindowStart, $eventWindowEnd);
            }
        } else {
            $findings[] = self::finding('auth_audit_unavailable', 'unknown', null,
                'Authentication management events are unavailable or audit coverage is partial.',
                'Check host journal retention and the WHM audit source status before interpreting this report.',
                null, gmdate('Y-m-d\TH:i:s\Z', max(0, $generatedAt - self::AUTH_EVENT_WINDOW_SECONDS)),
                gmdate('Y-m-d\TH:i:s\Z', max(0, $generatedAt)));
        }

        $unmeasured = ['credential_strength' => 'Weak or reused passwords are not inspected.'];
        if ($podmanWindow === null) {
            $unmeasured['ea_podman_counter_rates'] = 'A complete, fresh sample with a matching process set and monotonic counters is not available; Podman counter deltas and thresholds were not evaluated.';
        } elseif (!$podmanWindow['auth_available']) {
            $unmeasured['ea_podman_authentication_failures'] = 'At least one matched process lacks the optional authentication-failure counter.';
        }
        if (!$podmanMetricsValid) {
            $unmeasured['ea_podman_metrics'] = 'No fresh, verified root-owned EA Podman snapshot was available.';
        }
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

    /** @return array{version:int,thresholds:array{evictions_per_window:int,operations_per_second:int,auth_failures_per_window:int}} */
    private static function defaultSecurityReportPolicy(): array
    {
        return [
            'version' => 1,
            'thresholds' => [
                'evictions_per_window' => 0,
                'operations_per_second' => 0,
                'auth_failures_per_window' => 0,
            ],
        ];
    }

    /** @param array<string,mixed>|null $metrics */
    private static function validPodmanMetrics(?array $metrics, int $generatedAt): bool
    {
        if ($metrics === null || ($metrics['success'] ?? null) !== true || !in_array($metrics['version'] ?? null, [1, 2], true)
            || !is_bool($metrics['partial'] ?? null) || !is_bool($metrics['scan_complete'] ?? null)
            || !is_int($metrics['sampled_at'] ?? null) || $metrics['sampled_at'] < $generatedAt - 1800
            || $metrics['sampled_at'] > $generatedAt) {
            return false;
        }
        foreach (['discovered_count', 'sampled_count', 'reachable_count', 'unmeasured_count', 'skipped_count', 'unverified_account_count'] as $field) {
            if (!is_int($metrics[$field] ?? null) || $metrics[$field] < 0 || $metrics[$field] > 10240000) {
                return false;
            }
        }
        if ($metrics['sampled_count'] !== $metrics['reachable_count'] + $metrics['unmeasured_count']
            || $metrics['sampled_count'] + $metrics['skipped_count'] !== $metrics['discovered_count']) {
            return false;
        }
        if (!is_array($metrics['backend_counts'] ?? null) || !is_array($metrics['sampled_backend_counts'] ?? null)) {
            return false;
        }
        foreach (['backend_counts', 'sampled_backend_counts'] as $field) {
            $keys = array_keys($metrics[$field]);
            sort($keys);
            if ($keys !== ['redis', 'valkey']) {
                return false;
            }
            foreach ($metrics[$field] as $count) {
                if (!is_int($count) || $count < 0 || $count > 10240000) {
                    return false;
                }
            }
        }
        if (array_sum($metrics['backend_counts']) !== $metrics['discovered_count']
            || array_sum($metrics['sampled_backend_counts']) !== $metrics['sampled_count']) {
            return false;
        }
        $metricKeys = ['connected_clients', 'evicted_keys', 'keyspace_hits', 'keyspace_misses', 'memory_used_bytes', 'total_commands_processed'];
        if (!is_array($metrics['metrics'] ?? null)) {
            return false;
        }
        $actualMetricKeys = array_keys($metrics['metrics']);
        sort($actualMetricKeys);
        sort($metricKeys);
        if ($actualMetricKeys !== $metricKeys) {
            return false;
        }
        foreach ($metrics['metrics'] as $value) {
            if (!is_int($value) || $value < 0) {
                return false;
            }
        }
        if ($metrics['version'] === 2 && !self::validPodmanCounterWindow($metrics['counter_window'] ?? null, $metrics['sampled_at'], $generatedAt)) {
            return false;
        }
        return true;
    }

    /** @param mixed $window */
    private static function validPodmanCounterWindow(mixed $window, int $sampledAt, int $generatedAt): bool
    {
        if (!is_array($window)) {
            return false;
        }
        $keys = array_keys($window);
        sort($keys);
        $expected = ['auth_available', 'max_auth_failures_delta', 'max_evictions_delta',
            'max_operations_per_second', 'process_count', 'reason', 'sampled_at', 'status',
            'window_seconds', 'window_start_at'];
        sort($expected);
        $reasons = ['first_sample', 'incomplete_scan', 'identity_missing', 'invalid_identity', 'duplicate_identity',
            'state_unavailable', 'invalid_baseline', 'non_monotonic_time', 'stale_baseline',
            'process_set_changed', 'counter_reset', 'no_processes', 'matched_process_set'];
        if ($keys !== $expected || !in_array($window['status'] ?? null, ['unknown', 'measured'], true)
            || !in_array($window['reason'] ?? null, $reasons, true) || !is_bool($window['auth_available'] ?? null)
            || !is_int($window['sampled_at'] ?? null) || $window['sampled_at'] !== $sampledAt
            || $window['sampled_at'] > $generatedAt) {
            return false;
        }
        foreach (['window_start_at', 'window_seconds', 'process_count', 'max_evictions_delta',
            'max_operations_per_second', 'max_auth_failures_delta'] as $field) {
            if (!is_int($window[$field] ?? null) || $window[$field] < 0 || $window[$field] > 1_000_000_000_000_000) {
                return false;
            }
        }
        if ($window['status'] === 'measured') {
            return $window['reason'] === 'matched_process_set' && $window['process_count'] >= 1
                && $window['process_count'] <= 256 && $window['window_seconds'] >= 1
                && $window['window_seconds'] <= self::MAX_RATE_WINDOW_SECONDS
                && $window['window_start_at'] + $window['window_seconds'] === $sampledAt
                && ($window['auth_available'] || $window['max_auth_failures_delta'] === 0);
        }
        return $window['reason'] !== 'matched_process_set' && $window['window_start_at'] === 0
            && $window['window_seconds'] === 0 && $window['process_count'] === 0
            && $window['max_evictions_delta'] === 0 && $window['max_operations_per_second'] === 0
            && $window['auth_available'] === false && $window['max_auth_failures_delta'] === 0;
    }

    /** @param list<array<string,mixed>> $findings */
    private static function appendMetricFinding(array &$findings, string $category, int $count, string $severity,
        string $evidence, int $sampledAt, string $recommendation): void
    {
        if ($count > 0) {
            $sampleTime = gmdate('Y-m-d\TH:i:s\Z', $sampledAt);
            $findings[] = self::finding($category, $severity, $count, $evidence,
                $recommendation, $sampleTime, $sampleTime, $sampleTime);
        }
    }

    /** @return array<string,mixed> */
    private static function finding(string $category, string $severity, ?int $count, string $evidence,
        string $recommendation, ?string $sampledAt = null, ?string $windowStart = null,
        ?string $windowEnd = null): array
    {
        return [
            'category' => $category,
            'count' => $count,
            'evidence' => $evidence,
            'recommendation' => $recommendation,
            'sampled_at_utc' => $sampledAt,
            'severity' => $severity,
            'window_start_utc' => $windowStart,
            'window_end_utc' => $windowEnd,
        ];
    }
}
