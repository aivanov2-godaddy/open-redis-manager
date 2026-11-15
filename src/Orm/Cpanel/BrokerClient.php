<?php
declare(strict_types=1);

namespace Orm\Cpanel;

use Throwable;

/** Sends fixed ORM operations to the local broker and validates their bounded replies. */
final class BrokerClient
{
    private const SOCKET_PATH = 'unix:///run/orm/broker.sock';
    private const MAX_RESPONSE_BYTES = 4096;
    private const OPERATIONS = [
        'instance.status',
        'instance.metrics',
        'instance.provision',
        'instance.configure',
        'instance.start',
        'instance.stop',
        'backup.list',
        'backup.create',
    ];
    private const MEMORY_POLICIES = [
        'allkeys-lru', 'allkeys-lfu', 'allkeys-random', 'volatile-lru',
        'volatile-lfu', 'volatile-random', 'volatile-ttl', 'noeviction',
    ];

    /** @param null|callable(string): ?string $exchange Test seam; production uses the fixed Unix socket. */
    public function __construct(private readonly mixed $exchange = null)
    {
        if ($exchange !== null && !is_callable($exchange)) {
            throw new \InvalidArgumentException('The broker exchange must be callable.');
        }
    }

    /** @return array{success:bool,version:int,state?:string,preset?:string,config?:array{memory_mib:int,maxmemory_policy:string,maxclients:int,timeout:int},backups?:list<array{id:string,created_at:int,size_bytes:int}>,backup?:array{id:string,created_at:int,size_bytes:int},error?:string,memory_used_bytes?:int,memory_peak_bytes?:int,connected_clients?:int,uptime_seconds?:int,commands_per_second?:int,keyspace_hits?:int,keyspace_misses?:int,sampled_at?:int,stale?:bool,retained?:bool}|null */
    public function request(string $operation, ?string $preset = null, ?array $config = null): ?array
    {
        if (!in_array($operation, self::OPERATIONS, true)) {
            return null;
        }
        if ($preset !== null && ($operation !== 'instance.provision'
            || !in_array($preset, ['wordpress', 'laravel', 'magento', 'session', 'generic'], true))) {
            return null;
        }
        if ($config !== null && ($operation !== 'instance.configure' || $preset !== null || !self::validConfig($config))) {
            return null;
        }
        if ($operation === 'instance.configure' && $config === null) {
            return null;
        }

        if ($config !== null) {
            $payload = [
                'maxclients' => $config['maxclients'],
                'maxmemory_policy' => $config['maxmemory_policy'],
                'memory_mib' => $config['memory_mib'],
                'operation' => $operation,
                'timeout' => $config['timeout'],
                'version' => 1,
            ];
        } else {
            $payload = $preset === null
                ? ['operation' => $operation, 'version' => 1]
                : ['operation' => $operation, 'preset' => $preset, 'version' => 1];
        }
        $request = json_encode(
            $payload,
            JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
        ) . "\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request)
            : ($this->exchange)($request);
        if (!is_string($response) || $response === '' || strlen($response) > self::MAX_RESPONSE_BYTES
            || !str_ends_with($response, "\n") || substr_count($response, "\n") !== 1) {
            return null;
        }

        try {
            $decoded = json_decode(substr($response, 0, -1), true, 4, JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            return null;
        }
        if (!is_array($decoded) || ($decoded['version'] ?? null) !== 1 || !is_bool($decoded['success'] ?? null)) {
            return null;
        }

        if ($decoded['success']) {
            if ($operation === 'instance.configure' && !array_key_exists('config', $decoded)) {
                return null;
            }
            $keys = array_keys($decoded);
            sort($keys);
            if ($operation === 'backup.list') {
                if ($keys !== ['backups', 'success', 'version'] || !is_array($decoded['backups'])
                    || !array_is_list($decoded['backups']) || count($decoded['backups']) > 3) {
                    return null;
                }
                $lastCreatedAt = PHP_INT_MAX;
                foreach ($decoded['backups'] as $backup) {
                    if (!self::validBackup($backup) || $backup['created_at'] > $lastCreatedAt) {
                        return null;
                    }
                    $lastCreatedAt = $backup['created_at'];
                }
                return $decoded;
            }
            if ($operation === 'backup.create') {
                return $keys === ['backup', 'success', 'version'] && self::validBackup($decoded['backup'] ?? null)
                    ? $decoded
                    : null;
            }
            if (in_array('memory_used_bytes', $keys, true)) {
                $metricKeys = ['commands_per_second', 'connected_clients', 'keyspace_hits', 'keyspace_misses',
                    'memory_peak_bytes', 'memory_used_bytes', 'retained', 'sampled_at', 'stale', 'success', 'uptime_seconds', 'version'];
                sort($metricKeys);
                if ($keys !== $metricKeys) {
                    return null;
                }
                foreach (['memory_used_bytes', 'memory_peak_bytes', 'connected_clients', 'uptime_seconds',
                    'commands_per_second', 'keyspace_hits', 'keyspace_misses'] as $field) {
                    if (!is_int($decoded[$field]) || $decoded[$field] < 0 || $decoded[$field] > 9_000_000_000_000_000) {
                        return null;
                    }
                }
                if (!is_int($decoded['sampled_at']) || $decoded['sampled_at'] < 0 || $decoded['sampled_at'] > 9_999_999_999
                    || !is_bool($decoded['stale']) || !is_bool($decoded['retained'])
                    || ($decoded['stale'] && !$decoded['retained'])) {
                    return null;
                }
                return $decoded;
            }
            if (!in_array($decoded['state'] ?? null, ['not_configured', 'stopped', 'starting', 'running', 'stopping', 'failed'], true)) {
                return null;
            }
            if (array_key_exists('config', $decoded)) {
                if (!in_array($decoded['preset'] ?? null, ['wordpress', 'laravel', 'magento', 'session', 'generic'], true)
                    || !self::validConfig($decoded['config'])
                    || $keys !== ['config', 'preset', 'state', 'success', 'version']) {
                    return null;
                }
                return [
                    'success' => true,
                    'state' => $decoded['state'],
                    'version' => 1,
                    'preset' => $decoded['preset'],
                    'config' => $decoded['config'],
                ];
            }
            if (array_key_exists('preset', $decoded)) {
                if (!in_array($decoded['preset'], ['wordpress', 'laravel', 'magento', 'session', 'generic'], true)
                    || $keys !== ['preset', 'state', 'success', 'version']) {
                    return null;
                }
                return ['success' => true, 'state' => $decoded['state'], 'version' => 1, 'preset' => $decoded['preset']];
            }
            if ($keys !== ['state', 'success', 'version']) {
                return null;
            }
            return ['success' => true, 'state' => $decoded['state'], 'version' => 1];
        }

        $keys = array_keys($decoded);
        sort($keys);
        if ($keys !== ['error', 'success', 'version']
            || !in_array($decoded['error'], [
                'invalid_request', 'not_authorized', 'operation_failed', 'instance_unavailable',
                'instance_exists', 'storage_unavailable', 'backend_policy_required', 'backend_unavailable',
                'service_failed', 'not_configured', 'not_running', 'metrics_unavailable', 'rate_limited',
                'configuration_unavailable', 'configuration_failed', 'configuration_storage_unavailable',
                'configuration_uncertain',
                'backup_failed', 'backup_invalid', 'backup_in_progress', 'backup_retention_failed',
                'backup_storage_unavailable',
            ], true)) {
            return null;
        }
        return ['success' => false, 'error' => $decoded['error'], 'version' => 1];
    }

    private static function validConfig(mixed $config): bool
    {
        if (!is_array($config)) {
            return false;
        }
        $keys = array_keys($config);
        sort($keys);
        if ($keys !== ['maxclients', 'maxmemory_policy', 'memory_mib', 'timeout']) {
            return false;
        }
        return is_int($config['memory_mib']) && $config['memory_mib'] >= 8 && $config['memory_mib'] <= 64
            && is_int($config['maxclients']) && $config['maxclients'] >= 10 && $config['maxclients'] <= 100
            && is_int($config['timeout']) && $config['timeout'] >= 0 && $config['timeout'] <= 300
            && is_string($config['maxmemory_policy']) && in_array($config['maxmemory_policy'], self::MEMORY_POLICIES, true);
    }

    private static function validBackup(mixed $backup): bool
    {
        if (!is_array($backup)) {
            return false;
        }
        $keys = array_keys($backup);
        sort($keys);
        if ($keys !== ['created_at', 'id', 'size_bytes'] || !is_string($backup['id'])
            || preg_match('/\Asnapshot-([0-9]{10})-[a-f0-9]{8}[.]rdb\z/', $backup['id'], $matches) !== 1
            || !is_int($backup['created_at']) || $backup['created_at'] !== (int) $matches[1]
            || !is_int($backup['size_bytes']) || $backup['size_bytes'] < 1 || $backup['size_bytes'] > 134_217_728) {
            return false;
        }
        return true;
    }

    /** @return array{success:bool,version:int,offset:int,total:int,entries:list<array{username:string,state:string}>}|null */
    public function requestFleetPage(int $offset): ?array
    {
        if ($offset < 0 || $offset > 10000) {
            return null;
        }
        $request = json_encode(
            ['offset' => $offset, 'operation' => 'fleet.list', 'version' => 1],
            JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
        ) . "\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request)
            : ($this->exchange)($request);
        if (!is_string($response) || $response === '' || strlen($response) > self::MAX_RESPONSE_BYTES
            || !str_ends_with($response, "\n") || substr_count($response, "\n") !== 1) {
            return null;
        }

        try {
            $decoded = json_decode(substr($response, 0, -1), true, 6, JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            return null;
        }
        if (!is_array($decoded) || ($decoded['success'] ?? null) !== true || ($decoded['version'] ?? null) !== 1
            || ($decoded['offset'] ?? null) !== $offset || !is_int($decoded['total'] ?? null)
            || $decoded['total'] < 0 || $decoded['total'] > 10000 || !is_array($decoded['entries'] ?? null)
            || count($decoded['entries']) > 4) {
            return null;
        }
        $keys = array_keys($decoded);
        sort($keys);
        if ($keys !== ['entries', 'offset', 'success', 'total', 'version']) {
            return null;
        }
        $previous = '';
        foreach ($decoded['entries'] as $entry) {
            if (!is_array($entry) || !is_string($entry['username'] ?? null)
                || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $entry['username']) !== 1
                || $entry['username'] <= $previous || !is_string($entry['state'] ?? null)
                || !in_array($entry['state'], ['stopped', 'starting', 'running', 'stopping', 'failed', 'unhealthy'], true)) {
                return null;
            }
            $entryKeys = array_keys($entry);
            sort($entryKeys);
            if ($entryKeys !== ['state', 'username']) {
                return null;
            }
            $previous = $entry['username'];
        }
        if ($offset + count($decoded['entries']) > $decoded['total']) {
            return null;
        }
        return $decoded;
    }

    private function exchangeWithLocalBroker(string $request): ?string
    {
        $errno = 0;
        $error = '';
        $stream = @stream_socket_client(
            self::SOCKET_PATH,
            $errno,
            $error,
            5.0,
            STREAM_CLIENT_CONNECT
        );
        if (!is_resource($stream)) {
            return null;
        }

        stream_set_timeout($stream, 35);
        $written = 0;
        while ($written < strlen($request)) {
            $count = @fwrite($stream, substr($request, $written));
            if (!is_int($count) || $count <= 0) {
                fclose($stream);
                return null;
            }
            $written += $count;
        }
        if (!@stream_socket_shutdown($stream, STREAM_SHUT_WR)) {
            fclose($stream);
            return null;
        }

        $response = @stream_get_contents($stream, self::MAX_RESPONSE_BYTES + 1);
        $metadata = stream_get_meta_data($stream);
        fclose($stream);
        if (($metadata['timed_out'] ?? false) === true) {
            return null;
        }
        return is_string($response) ? $response : null;
    }
}
