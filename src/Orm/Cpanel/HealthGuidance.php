<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** Turns validated account metrics into bounded, advisory-only health findings. */
final class HealthGuidance
{
    private const STATES = ['not_configured', 'stopped', 'starting', 'running', 'stopping', 'failed'];

    /** @return array{state:string,findings:list<array{severity:string,title:string,detail:string,recommendation:string}>} */
    public static function build(?array $instanceStatus, ?array $metrics): array
    {
        $findings = [];
        $statusKnown = ($instanceStatus['success'] ?? null) === true
            && in_array($instanceStatus['state'] ?? null, self::STATES, true);
        if (!$statusKnown) {
            return self::result('unavailable', [[
                'severity' => 'info',
                'title' => 'Cache state could not be verified',
                'detail' => 'The broker did not return a verified instance state.',
                'recommendation' => 'Reload later. Contact your hosting provider if the status remains unavailable.',
            ]]);
        }

        $serviceState = $instanceStatus['state'];
        if ($serviceState === 'not_configured') {
            return self::result('setup', [[
                'severity' => 'info',
                'title' => 'No cache instance is configured',
                'detail' => 'Performance guidance is available after an instance has been initialized.',
                'recommendation' => 'Choose a setup preset to initialize your account cache.',
            ]]);
        }
        if ($serviceState === 'stopped' || $serviceState === 'failed') {
            $failed = $serviceState === 'failed';
            return self::result('attention', [[
                'severity' => $failed ? 'warning' : 'info',
                'title' => $failed ? 'Cache service needs attention' : 'Cache service is stopped',
                'detail' => $failed
                    ? 'The broker reports that the cache service failed.'
                    : 'A stopped cache cannot serve application requests.',
                'recommendation' => $failed
                    ? 'Check the service status and contact your hosting provider before retrying.'
                    : 'Start the cache when your application is ready to use it.',
            ]]);
        }
        if ($serviceState !== 'running') {
            return self::result('pending', [[
                'severity' => 'info',
                'title' => 'Cache service is changing state',
                'detail' => 'Performance findings are paused while the service is starting or stopping.',
                'recommendation' => 'Refresh the page after the service reaches a stable state.',
            ]]);
        }

        if (($metrics['success'] ?? null) !== true) {
            return self::result('unavailable', [[
                'severity' => 'info',
                'title' => 'Current metrics are unavailable',
                'detail' => 'ORM could not verify current cache metrics, so it is not evaluating performance thresholds.',
                'recommendation' => 'Refresh later. Treat any saved sample as historical until a current sample is available.',
            ]]);
        }
        if (($metrics['stale'] ?? null) === true) {
            return self::result('stale', [[
                'severity' => 'info',
                'title' => 'Performance guidance is paused for stale metrics',
                'detail' => 'The displayed values are a saved sample, not a current reading.',
                'recommendation' => 'Wait for a current sample before acting on memory, client, or hit-ratio guidance.',
            ]]);
        }

        $configuration = $instanceStatus['config'] ?? null;
        $memoryLimitBytes = is_array($configuration) && is_int($configuration['memory_mib'] ?? null)
            && $configuration['memory_mib'] >= 8 && $configuration['memory_mib'] <= 64
            ? $configuration['memory_mib'] * 1024 * 1024
            : null;
        if ($memoryLimitBytes !== null && is_int($metrics['memory_used_bytes'] ?? null)
            && $metrics['memory_used_bytes'] >= 0) {
            $memoryPercent = ($metrics['memory_used_bytes'] / $memoryLimitBytes) * 100;
            if ($memoryPercent >= 85) {
                $shownPercent = (string) (int) round($memoryPercent);
                $findings[] = [
                    'severity' => 'warning',
                    'title' => 'Memory use is approaching the configured limit',
                    'detail' => 'The current Redis used-memory counter is about ' . $shownPercent . '% of the configured memory ceiling.',
                    'recommendation' => 'Review cache growth and eviction behavior. If the workload needs more capacity, ask your provider about the package limit before raising the setting.',
                ];
            }
        }

        $clientLimit = is_array($configuration) && is_int($configuration['maxclients'] ?? null)
            && $configuration['maxclients'] >= 10 && $configuration['maxclients'] <= 100
            ? $configuration['maxclients']
            : null;
        if ($clientLimit !== null && is_int($metrics['connected_clients'] ?? null)
            && $metrics['connected_clients'] >= 0
            && ($metrics['connected_clients'] / $clientLimit) >= 0.85) {
            $findings[] = [
                'severity' => 'warning',
                'title' => 'Connected clients are near the configured limit',
                'detail' => 'The current client count is at least 85% of the configured client ceiling.',
                'recommendation' => 'Review application connection pooling and ask your provider before increasing the client ceiling.',
            ];
        }

        $hits = $metrics['keyspace_hits'] ?? null;
        $misses = $metrics['keyspace_misses'] ?? null;
        if (is_int($hits) && $hits >= 0 && is_int($misses) && $misses >= 0 && ($hits + $misses) >= 100) {
            $hitRatio = $hits / ($hits + $misses);
            if ($hitRatio < 0.5) {
                $findings[] = [
                    'severity' => 'review',
                    'title' => 'The cumulative cache hit ratio is below 50%',
                    'detail' => 'Since the current cache process started, fewer than half of the counted key lookups were hits.',
                    'recommendation' => 'Review whether the application is storing and reusing the intended cache entries. This cumulative ratio can change with workload and resets when the service restarts.',
                ];
            }
        }

        if ($findings === []) {
            $findings[] = [
                'severity' => 'info',
                'title' => 'No current advisory thresholds were crossed',
                'detail' => 'This check covers configured memory, connected clients, and the cumulative hit ratio when enough lookups are available.',
                'recommendation' => 'Continue to review metrics over time. This result does not verify application connectivity or guarantee performance.',
            ];
            return self::result('clear', $findings);
        }

        return self::result('review', $findings);
    }

    /** @param list<array{severity:string,title:string,detail:string,recommendation:string}> $findings
     *  @return array{state:string,findings:list<array{severity:string,title:string,detail:string,recommendation:string}>}
     */
    private static function result(string $state, array $findings): array
    {
        return ['state' => $state, 'findings' => $findings];
    }
}
