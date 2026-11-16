<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** Builds a minimal support report from already-validated, account-scoped broker data. */
final class DiagnosticReport
{
    private const STATES = ['not_configured', 'stopped', 'starting', 'running', 'stopping', 'failed'];
    private const PRESETS = ['wordpress', 'laravel', 'magento', 'session', 'generic'];
    private const POLICIES = [
        'allkeys-lru', 'allkeys-lfu', 'allkeys-random', 'volatile-lru',
        'volatile-lfu', 'volatile-random', 'volatile-ttl', 'noeviction',
    ];

    /** @return array<string,mixed> */
    public static function build(?array $instanceStatus, ?array $metrics, ?int $generatedAt = null): array
    {
        $statusOk = ($instanceStatus['success'] ?? null) === true
            && in_array($instanceStatus['state'] ?? null, self::STATES, true);
        $state = $statusOk ? $instanceStatus['state'] : 'unavailable';
        $preset = $statusOk && in_array($instanceStatus['preset'] ?? null, self::PRESETS, true)
            ? $instanceStatus['preset']
            : null;
        $configuration = $statusOk ? self::configuration($instanceStatus['config'] ?? null) : null;

        return [
            'generated_at_utc' => gmdate('c', $generatedAt ?? time()),
            'schema_version' => 1,
            'instance' => [
                'state' => $state,
                'preset' => $preset,
                'configuration' => $configuration,
            ],
            'connection' => [
                'transport' => 'account_private_unix_socket',
                'tcp_enabled' => false,
                'redis_auth_configured' => false,
            ],
            'metrics' => self::metrics($metrics),
            'excluded_data' => [
                'credentials and tokens',
                'Redis keys and values',
                'application payloads and sessions',
                'raw Redis INFO output and command output',
                'logs and other account files',
                'account names and filesystem paths',
            ],
        ];
    }

    /** @return array{memory_mib:int,maxmemory_policy:string,maxclients:int,timeout:int}|null */
    private static function configuration(mixed $configuration): ?array
    {
        if (!is_array($configuration)) {
            return null;
        }
        $keys = array_keys($configuration);
        sort($keys);
        if ($keys !== ['maxclients', 'maxmemory_policy', 'memory_mib', 'timeout']) {
            return null;
        }
        if (!is_int($configuration['memory_mib']) || $configuration['memory_mib'] < 8 || $configuration['memory_mib'] > 64
            || !is_int($configuration['maxclients']) || $configuration['maxclients'] < 10 || $configuration['maxclients'] > 100
            || !is_int($configuration['timeout']) || $configuration['timeout'] < 0 || $configuration['timeout'] > 300
            || !is_string($configuration['maxmemory_policy']) || !in_array($configuration['maxmemory_policy'], self::POLICIES, true)) {
            return null;
        }
        return [
            'memory_mib' => $configuration['memory_mib'],
            'maxmemory_policy' => $configuration['maxmemory_policy'],
            'maxclients' => $configuration['maxclients'],
            'timeout' => $configuration['timeout'],
        ];
    }

    /** @return array<string,int|string|bool>|null */
    private static function metrics(?array $metrics): ?array
    {
        if (($metrics['success'] ?? null) !== true) {
            return null;
        }
        $numericFields = [
            'memory_used_bytes', 'memory_peak_bytes', 'connected_clients', 'uptime_seconds',
            'commands_per_second', 'keyspace_hits', 'keyspace_misses',
        ];
        foreach ($numericFields as $field) {
            if (!is_int($metrics[$field] ?? null) || $metrics[$field] < 0 || $metrics[$field] > 9_000_000_000_000_000) {
                return null;
            }
        }
        if (!is_int($metrics['sampled_at'] ?? null) || $metrics['sampled_at'] < 0 || $metrics['sampled_at'] > 9_999_999_999
            || !is_bool($metrics['stale'] ?? null) || !is_bool($metrics['retained'] ?? null)
            || ($metrics['stale'] && !$metrics['retained'])) {
            return null;
        }
        return [
            'captured_at_utc' => gmdate('c', $metrics['sampled_at']),
            'stale' => $metrics['stale'],
            'sample_saved' => $metrics['retained'],
            'memory_used_bytes' => $metrics['memory_used_bytes'],
            'memory_peak_bytes' => $metrics['memory_peak_bytes'],
            'connected_clients' => $metrics['connected_clients'],
            'uptime_seconds' => $metrics['uptime_seconds'],
            'commands_per_second' => $metrics['commands_per_second'],
            'keyspace_hits' => $metrics['keyspace_hits'],
            'keyspace_misses' => $metrics['keyspace_misses'],
        ];
    }
}
