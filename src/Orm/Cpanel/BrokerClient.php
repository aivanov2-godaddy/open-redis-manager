<?php
declare(strict_types=1);

namespace Orm\Cpanel;

use Throwable;

/** Sends fixed ORM operations to the local broker and validates their bounded replies. */
final class BrokerClient
{
    private const SOCKET_PATH = 'unix:///run/orm/broker.sock';
    private const MAX_RESPONSE_BYTES = 262144;
    private const MAX_DIAGNOSTIC_INTEGER = 9_000_000_000_000_000;
    private const BACKUP_OPERATION_TIMEOUT_SECONDS = 180;
    private const OPERATIONS = [
        'instance.status',
        'instance.auth.status',
        'instance.auth.rotate',
        'instance.auth.disable',
        'instance.metrics',
        'metrics.history',
        'instance.provision',
        'instance.configure',
        'instance.start',
        'instance.stop',
        'backup.list',
        'backup.create',
        'backup.restore',
        'provider.exposure',
        'provider.branding',
        'provider.resellers',
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

    /** @return array{success:bool,version:int,state?:string,preset?:string,exposure?:string,branding?:array{product_name:string,logo_png_base64:string,support_url:string,preset:string,primary_color:string,secondary_color:string,surface_color:string,text_color:string,footer_visible:bool},resellers?:list<array{owner:string,account_count:int,active_instances:int,memory_mib:int,max_instances:int,max_memory_mib:int}>,config?:array{memory_mib:int,maxmemory_policy:string,maxclients:int,timeout:int},backups?:list<array{id:string,created_at:int,size_bytes:int}>,backup?:array{id:string,created_at:int,size_bytes:int},backup_id?:string,safety_backup_id?:string,error?:string,memory_used_bytes?:int,memory_peak_bytes?:int,connected_clients?:int,uptime_seconds?:int,commands_per_second?:int,keyspace_hits?:int,keyspace_misses?:int,sampled_at?:int,stale?:bool,retained?:bool}|null */
    public function request(string $operation, ?string $preset = null, ?array $config = null, ?string $backupId = null, ?string $range = null): ?array
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
        if (($operation === 'backup.restore') !== ($backupId !== null)
            || ($backupId !== null && !self::validBackupId($backupId))) {
            return null;
        }
        if (($operation === 'metrics.history') !== ($range !== null)
            || ($range !== null && !in_array($range, ['24h', '7d'], true))) {
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
        } elseif ($operation === 'backup.restore') {
            $payload = [
                'backup_id' => $backupId,
                'operation' => $operation,
                'version' => 1,
            ];
        } elseif ($operation === 'metrics.history') {
            $payload = ['operation' => $operation, 'range' => $range, 'version' => 1];
        } else {
            $payload = $preset === null
                ? ['operation' => $operation, 'version' => 1]
                : ['operation' => $operation, 'preset' => $preset, 'version' => 1];
        }
        $request = json_encode(
            $payload,
            JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
        ) . "\n";
        $timeoutSeconds = in_array($operation, ['backup.create', 'backup.restore'], true)
            ? self::BACKUP_OPERATION_TIMEOUT_SECONDS : 35;
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request, $timeoutSeconds)
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

        $keys = array_keys($decoded);
        sort($keys);
        if ($decoded['success']) {
            if ($operation === 'instance.auth.status') {
                return $keys === ['auth_configured', 'success', 'version']
                    && is_bool($decoded['auth_configured'] ?? null) ? $decoded : null;
            }
            if ($operation === 'instance.auth.rotate') {
                return $keys === ['auth_configured', 'secret', 'success', 'version']
                    && ($decoded['auth_configured'] ?? null) === true
                    && is_string($decoded['secret'] ?? null)
                    && preg_match('/\A[A-Za-z0-9_-]{43}\z/', $decoded['secret']) === 1
                    ? $decoded : null;
            }
            if ($operation === 'instance.auth.disable') {
                return $keys === ['auth_configured', 'success', 'version']
                    && ($decoded['auth_configured'] ?? null) === false ? $decoded : null;
            }
            if ($operation === 'provider.exposure') {
                return $keys === ['exposure', 'success', 'version']
                    && in_array($decoded['exposure'] ?? null, ['simple', 'developer', 'advanced'], true)
                    ? $decoded : null;
            }
            if ($operation === 'provider.branding') {
                if ($keys !== ['branding', 'success', 'version'] || !is_array($decoded['branding'])) {
                    return null;
                }
                $branding = $decoded['branding'];
                $brandingKeys = array_keys($branding);
                sort($brandingKeys);
                if ($brandingKeys !== ['footer_visible', 'logo_png_base64', 'preset', 'primary_color', 'product_name', 'secondary_color', 'support_url', 'surface_color', 'text_color']
                    || !is_string($branding['product_name'])
                    || preg_match('/\A[A-Za-z0-9][A-Za-z0-9 .&()+\/_-]{0,47}\z/', $branding['product_name']) !== 1
                    || !is_string($branding['support_url']) || !self::validBrandSupportUrl($branding['support_url'])
                    || !is_string($branding['preset']) || !in_array($branding['preset'], ['custom', 'orm', 'underhost', 'redis', 'valkey'], true)
                    || !is_string($branding['primary_color']) || !self::isBrandHexColor($branding['primary_color'])
                    || !is_string($branding['secondary_color']) || !self::isBrandHexColor($branding['secondary_color'])
                    || !is_string($branding['surface_color']) || !self::isBrandHexColor($branding['surface_color'])
                    || !is_string($branding['text_color']) || !self::isBrandHexColor($branding['text_color'])
                    || !self::hasBrandContrast($branding['primary_color'], '#FFFFFF')
                    || !self::hasBrandContrast($branding['primary_color'], $branding['surface_color'])
                    || !self::hasBrandContrast($branding['secondary_color'], $branding['surface_color'])
                    || !self::hasBrandContrast($branding['text_color'], '#FFFFFF')
                    || !self::hasBrandContrast($branding['text_color'], $branding['surface_color'])
                    || !is_bool($branding['footer_visible']) || !is_string($branding['logo_png_base64'])) {
                    return null;
                }
                $logo = $branding['logo_png_base64'];
                if ($logo !== '') {
                    $bytes = strlen($logo) <= 43700 ? base64_decode($logo, true) : false;
                    if (!is_string($bytes) || strlen($bytes) > 32768 || base64_encode($bytes) !== $logo) {
                        return null;
                    }
                    $image = getimagesizefromstring($bytes);
                    if (!is_array($image) || ($image['mime'] ?? null) !== 'image/png'
                        || $image[0] < 16 || $image[0] > 512 || $image[1] < 16 || $image[1] > 256) {
                        return null;
                    }
                }
                return [
                    'branding' => [
                        'product_name' => $branding['product_name'],
                        'logo_png_base64' => $logo,
                        'support_url' => $branding['support_url'],
                        'preset' => $branding['preset'],
                        'primary_color' => strtoupper($branding['primary_color']),
                        'secondary_color' => strtoupper($branding['secondary_color']),
                        'surface_color' => strtoupper($branding['surface_color']),
                        'text_color' => strtoupper($branding['text_color']),
                        'footer_visible' => $branding['footer_visible'],
                    ],
                    'success' => true,
                    'version' => 1,
                ];
            }
            if ($operation === 'provider.resellers') {
                if ($keys !== ['resellers', 'success', 'version'] || !is_array($decoded['resellers'])
                    || !array_is_list($decoded['resellers']) || count($decoded['resellers']) > 1000) {
                    return null;
                }
                $previousOwner = '';
                $resellers = [];
                foreach ($decoded['resellers'] as $reseller) {
                    if (!is_array($reseller)) {
                        return null;
                    }
                    $resellerKeys = array_keys($reseller);
                    sort($resellerKeys);
                    if ($resellerKeys !== ['account_count', 'active_instances', 'max_instances', 'max_memory_mib', 'memory_mib', 'owner']
                        || !is_string($reseller['owner']) || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $reseller['owner']) !== 1
                        || strcmp($reseller['owner'], $previousOwner) <= 0) {
                        return null;
                    }
                    foreach (['account_count' => 10000, 'active_instances' => 10000, 'max_instances' => 100000,
                        'max_memory_mib' => 1000000, 'memory_mib' => 640000] as $field => $maximum) {
                        if (!is_int($reseller[$field]) || $reseller[$field] < 0 || $reseller[$field] > $maximum) {
                            return null;
                        }
                    }
                    if ($reseller['active_instances'] > $reseller['account_count']) {
                        return null;
                    }
                    $previousOwner = $reseller['owner'];
                    $resellers[] = [
                        'owner' => $reseller['owner'],
                        'account_count' => $reseller['account_count'],
                        'active_instances' => $reseller['active_instances'],
                        'memory_mib' => $reseller['memory_mib'],
                        'max_instances' => $reseller['max_instances'],
                        'max_memory_mib' => $reseller['max_memory_mib'],
                    ];
                }
                return ['resellers' => $resellers, 'success' => true, 'version' => 1];
            }
            if ($operation === 'instance.configure' && !array_key_exists('config', $decoded)) {
                return null;
            }
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
            if ($operation === 'backup.restore') {
                return $keys === ['backup_id', 'safety_backup_id', 'state', 'success', 'version']
                    && self::validBackupId($decoded['backup_id'] ?? null)
                    && $decoded['backup_id'] === $backupId
                    && self::validBackupId($decoded['safety_backup_id'] ?? null)
                    && $decoded['state'] === 'running'
                    ? $decoded
                    : null;
            }
            if ($operation === 'metrics.history') {
                $keys = array_keys($decoded);
                sort($keys);
                if ($keys !== ['history', 'range', 'scheduled', 'success', 'version']
                    || ($decoded['range'] ?? null) !== $range || !is_bool($decoded['scheduled'] ?? null)
                    || !is_array($decoded['history'] ?? null) || !array_is_list($decoded['history'])
                    || count($decoded['history']) > ($range === '24h' ? 24 : 168)) {
                    return null;
                }
                $previousTimestamp = 0;
                foreach ($decoded['history'] as $sample) {
                    if (!is_array($sample)) {
                        return null;
                    }
                    $sampleKeys = array_keys($sample);
                    sort($sampleKeys);
                    if ($sampleKeys !== ['connected_clients', 'keyspace_hits', 'keyspace_misses', 'memory_used_bytes', 'sampled_at']) {
                        return null;
                    }
                    foreach (['sampled_at', 'memory_used_bytes', 'connected_clients', 'keyspace_hits', 'keyspace_misses'] as $field) {
                        if (!is_int($sample[$field]) || $sample[$field] < 0 || $sample[$field] > 9_000_000_000_000_000) {
                            return null;
                        }
                    }
                    if ($sample['sampled_at'] > 9_999_999_999 || $sample['sampled_at'] <= $previousTimestamp) {
                        return null;
                    }
                    $previousTimestamp = $sample['sampled_at'];
                }
                return $decoded;
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
                $expectedKeys = ['config', 'preset', 'state', 'success', 'version'];
                if (in_array($operation, ['instance.provision', 'instance.configure'], true)
                    && array_key_exists('policy_warnings', $decoded)) {
                    if (!self::validProviderPolicyWarnings($decoded['policy_warnings'])) {
                        return null;
                    }
                    $expectedKeys[] = 'policy_warnings';
                }
                sort($expectedKeys);
                if (!in_array($decoded['preset'] ?? null, ['wordpress', 'laravel', 'magento', 'session', 'generic'], true)
                    || !self::validConfig($decoded['config'])
                    || $keys !== $expectedKeys || (array_key_exists('policy_warnings', $decoded)
                        && !in_array($operation, ['instance.provision', 'instance.configure'], true))) {
                    return null;
                }
                $result = [
                    'success' => true,
                    'state' => $decoded['state'],
                    'version' => 1,
                    'preset' => $decoded['preset'],
                    'config' => $decoded['config'],
                ];
                if (array_key_exists('policy_warnings', $decoded)) {
                    $result['policy_warnings'] = $decoded['policy_warnings'];
                }
                return $result;
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
        if ($operation === 'backup.restore') {
            if (!in_array($decoded['error'] ?? null, [
                'invalid_request', 'not_authorized', 'operation_failed', 'not_configured', 'not_running',
                'provider_policy_unavailable',
                'backup_not_found', 'backup_invalid', 'backup_in_progress', 'backup_retention_failed',
                'backup_storage_unavailable', 'restore_validation_unavailable', 'restore_failed',
                'restore_rollback_failed', 'rate_limited',
            ], true)) {
                return null;
            }
            if ($keys === ['error', 'success', 'version']) {
                return ['success' => false, 'error' => $decoded['error'], 'version' => 1];
            }
            if ($keys === ['error', 'safety_backup_id', 'success', 'version']
                && self::validBackupId($decoded['safety_backup_id'])) {
                return ['success' => false, 'error' => $decoded['error'],
                    'safety_backup_id' => $decoded['safety_backup_id'], 'version' => 1];
            }
            return null;
        }
        if ($keys !== ['error', 'success', 'version']
            || !in_array($decoded['error'], [
                'invalid_request', 'not_authorized', 'operation_failed', 'operation_in_progress', 'instance_unavailable',
                'instance_exists', 'storage_unavailable', 'backend_policy_required', 'backend_unavailable',
                'provider_policy_denied', 'provider_policy_unavailable',
                'service_failed', 'not_configured', 'not_running', 'metrics_unavailable', 'rate_limited',
                'configuration_unavailable', 'configuration_failed', 'configuration_storage_unavailable',
                'configuration_uncertain',
                'auth_generation_failed', 'auth_rotation_failed', 'auth_disable_failed', 'auth_recovery_required',
                'backup_failed', 'backup_invalid', 'backup_in_progress', 'backup_retention_failed',
                'backup_storage_unavailable',
                'metrics_history_unavailable',
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

    /** @return array{auth_configured:bool,success:true,version:1,error?:string}|null */
    public function authStatus(): ?array
    {
        return $this->request('instance.auth.status');
    }

    /** @return array{auth_configured:true,secret:string,success:true,version:1,error?:string}|null */
    public function rotateAuth(): ?array
    {
        return $this->request('instance.auth.rotate');
    }

    /** @return array{auth_configured:false,success:true,version:1,error?:string}|null */
    public function disableAuth(): ?array
    {
        return $this->request('instance.auth.disable');
    }

    private static function isBrandHexColor(string $color): bool
    {
        return preg_match('/\A#[A-Fa-f0-9]{6}\z/', $color) === 1;
    }

    private static function hasBrandContrast(string $foreground, string $background): bool
    {
        $luminance = static function (string $color): float {
            $components = array_map(static fn (string $part): float => hexdec($part) / 255, str_split(substr($color, 1), 2));
            $linear = array_map(static fn (float $value): float => $value <= 0.04045 ? $value / 12.92 : (($value + 0.055) / 1.055) ** 2.4, $components);
            return 0.2126 * $linear[0] + 0.7152 * $linear[1] + 0.0722 * $linear[2];
        };
        $first = $luminance($foreground);
        $second = $luminance($background);
        return (max($first, $second) + 0.05) / (min($first, $second) + 0.05) >= 4.5;
    }

    private static function validBrandSupportUrl(string $url): bool
    {
        if ($url === '') {
            return true;
        }
        if (strlen($url) > 200 || preg_match('~\Ahttps://[^\s/?#@]+(?::[0-9]{1,5})?(?:/[A-Za-z0-9._\~!$&\'()*+,;=:@%/-]*)?\z~', $url) !== 1) {
            return false;
        }
        $parts = parse_url($url);
        $host = is_array($parts) ? ($parts['host'] ?? null) : null;
        $validHost = is_string($host) && (filter_var($host, FILTER_VALIDATE_IP) !== false
            || filter_var($host, FILTER_VALIDATE_DOMAIN, FILTER_FLAG_HOSTNAME) !== false);
        return is_array($parts) && strtolower($parts['scheme'] ?? '') === 'https'
            && $validHost
            && !isset($parts['user'], $parts['pass'], $parts['query'], $parts['fragment'])
            && filter_var($url, FILTER_VALIDATE_URL) !== false
            && (!isset($parts['port']) || ($parts['port'] >= 1 && $parts['port'] <= 65535));
    }

    private static function validProviderPolicyWarnings(mixed $warnings): bool
    {
        if (!is_array($warnings) || !array_is_list($warnings) || count($warnings) > 6) {
            return false;
        }
        foreach ($warnings as $warning) {
            if (!is_string($warning) || !in_array($warning, [
                'package_disabled', 'memory_limit_exceeded', 'client_limit_exceeded',
                'reseller_instance_quota_exceeded',
                'reseller_memory_quota_exceeded', 'reseller_usage_unavailable',
            ], true)) {
                return false;
            }
        }
        return count(array_unique($warnings)) === count($warnings);
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

    private static function validBackupId(mixed $backupId): bool
    {
        return is_string($backupId) && preg_match('/\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/', $backupId) === 1;
    }

    /** @return array{success:bool,version:int,backup_id?:string,safety_backup_id?:string,state?:string,error?:string}|null */
    public function restoreBackup(string $backupId): ?array
    {
        return $this->request('backup.restore', null, null, $backupId);
    }

    /** @return array{success:bool,version:int,range:string,scheduled:bool,history:list<array{sampled_at:int,memory_used_bytes:int,connected_clients:int,keyspace_hits:int,keyspace_misses:int}>}|null */
    public function metricsHistory(string $range): ?array
    {
        return $this->request('metrics.history', null, null, null, $range);
    }

    /** @return array{success:bool,version:int,offset:int,total:int,entries:list<array{username:string,state:string,backend:string,backups_available:bool,backups:list<array{id:string,created_at:int,size_bytes:int}>}>}|null */
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
            if ($entryKeys !== ['backend', 'backups', 'backups_available', 'state', 'username']
                || !in_array($entry['backend'] ?? null, ['redis', 'valkey', 'unknown'], true)
                || !is_bool($entry['backups_available']) || !is_array($entry['backups'])
                || count($entry['backups']) > 3
                || (!$entry['backups_available'] && $entry['backups'] !== [])) {
                return null;
            }
            foreach ($entry['backups'] as $backup) {
                if (!self::validBackup($backup)) {
                    return null;
                }
            }
            $previous = $entry['username'];
        }
        if ($offset + count($decoded['entries']) > $decoded['total']) {
            return null;
        }
        return $decoded;
    }

    /** @return array{success:true,version:1,account_count:int,managed_count:int,unconfigured_count:int,unverified_count:int,state_counts:array<string,int>,metrics:array<string,int>,partial:bool}|null */
    public function requestFleetSummary(): ?array
    {
        $request = "{\"operation\":\"fleet.summary\",\"version\":1}\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request, 60)
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
            || !is_bool($decoded['partial'] ?? null)) {
            return null;
        }
        $keys = array_keys($decoded);
        sort($keys);
        if ($keys !== ['account_count', 'managed_count', 'metrics', 'partial', 'state_counts', 'success', 'unconfigured_count', 'unverified_count', 'version']) {
            return null;
        }
        foreach (['account_count', 'managed_count', 'unconfigured_count', 'unverified_count'] as $field) {
            if (!is_int($decoded[$field]) || $decoded[$field] < 0 || $decoded[$field] > 10000) {
                return null;
            }
        }
        if ($decoded['managed_count'] + $decoded['unconfigured_count'] + $decoded['unverified_count'] !== $decoded['account_count']) {
            return null;
        }
        $stateKeys = ['failed', 'running', 'starting', 'stopped', 'stopping', 'unavailable'];
        if (!is_array($decoded['state_counts']) || array_keys($decoded['state_counts']) !== $stateKeys) {
            return null;
        }
        $stateTotal = 0;
        foreach ($stateKeys as $key) {
            if (!is_int($decoded['state_counts'][$key]) || $decoded['state_counts'][$key] < 0
                || $decoded['state_counts'][$key] > $decoded['managed_count']) {
                return null;
            }
            $stateTotal += $decoded['state_counts'][$key];
        }
        if ($stateTotal !== $decoded['managed_count']) {
            return null;
        }
        $legacyMetricKeys = ['alert_accounts', 'connected_clients', 'fresh_accounts', 'high_client_accounts',
            'high_memory_accounts', 'latest_sampled_at', 'low_hit_ratio_accounts',
            'memory_used_bytes', 'missing_accounts', 'stale_accounts'];
        $rateMetricKeys = ['eviction_activity_accounts', 'max_evictions_per_window', 'max_operations_per_second',
            'rate_accounts', 'rate_missing_accounts', 'rate_window_earliest_start_at', 'rate_window_latest_end_at',
            'rate_window_max_seconds', 'rate_window_min_seconds'];
        $extendedMetricKeys = [...$legacyMetricKeys, ...$rateMetricKeys];
        $authRateMetricKeys = ['auth_failure_accounts', 'auth_rate_accounts', 'auth_rate_missing_accounts',
            'auth_rate_window_earliest_start_at', 'auth_rate_window_latest_end_at', 'auth_rate_window_max_seconds',
            'auth_rate_window_min_seconds', 'max_auth_failures_per_window'];
        $authExtendedMetricKeys = [...$extendedMetricKeys, ...$authRateMetricKeys];
        sort($legacyMetricKeys);
        sort($extendedMetricKeys);
        sort($authExtendedMetricKeys);
        $actualMetricKeys = is_array($decoded['metrics']) ? array_keys($decoded['metrics']) : [];
        sort($actualMetricKeys);
        $hasAuthRateMetrics = $actualMetricKeys === $authExtendedMetricKeys;
        $hasRateMetrics = $hasAuthRateMetrics || $actualMetricKeys === $extendedMetricKeys;
        if (!$hasRateMetrics && $actualMetricKeys !== $legacyMetricKeys) {
            return null;
        }
        $metricKeys = $hasAuthRateMetrics ? $authExtendedMetricKeys
            : ($hasRateMetrics ? $extendedMetricKeys : $legacyMetricKeys);
        foreach ($metricKeys as $field) {
            $maximum = in_array($field, ['memory_used_bytes', 'connected_clients', 'latest_sampled_at'], true)
                ? self::MAX_DIAGNOSTIC_INTEGER : 10000;
            if (in_array($field, ['max_evictions_per_window', 'max_operations_per_second'], true)) {
                $maximum = self::MAX_DIAGNOSTIC_INTEGER;
            } elseif ($field === 'max_auth_failures_per_window') {
                $maximum = self::MAX_DIAGNOSTIC_INTEGER;
            } elseif (in_array($field, ['rate_window_earliest_start_at', 'rate_window_latest_end_at'], true)) {
                $maximum = 9_999_999_999;
            } elseif (in_array($field, ['auth_rate_window_earliest_start_at', 'auth_rate_window_latest_end_at'], true)) {
                $maximum = 9_999_999_999;
            } elseif (in_array($field, ['rate_window_max_seconds', 'rate_window_min_seconds'], true)) {
                $maximum = 26 * 60 * 60;
            } elseif (in_array($field, ['auth_rate_window_max_seconds', 'auth_rate_window_min_seconds'], true)) {
                $maximum = 26 * 60 * 60;
            }
            if (!is_int($decoded['metrics'][$field]) || $decoded['metrics'][$field] < 0
                || $decoded['metrics'][$field] > $maximum) {
                return null;
            }
        }
        $expectedPartial = $decoded['unverified_count'] > 0 || $decoded['state_counts']['unavailable'] > 0
            || $decoded['metrics']['stale_accounts'] > 0 || $decoded['metrics']['missing_accounts'] > 0;
        if ($hasRateMetrics) {
            $expectedPartial = $expectedPartial || $decoded['metrics']['rate_missing_accounts'] > 0;
        }
        if ($hasAuthRateMetrics) {
            $expectedPartial = $expectedPartial || $decoded['metrics']['auth_rate_missing_accounts'] > 0;
        }
        if ($decoded['metrics']['fresh_accounts'] + $decoded['metrics']['stale_accounts']
            + $decoded['metrics']['missing_accounts'] !== $decoded['managed_count']
            || $decoded['metrics']['alert_accounts'] > $decoded['metrics']['fresh_accounts']
            || $decoded['partial'] !== $expectedPartial) {
            return null;
        }
        if ($hasRateMetrics) {
            $metrics = $decoded['metrics'];
            if ($metrics['rate_accounts'] + $metrics['rate_missing_accounts'] !== $decoded['managed_count']
                || $metrics['eviction_activity_accounts'] > $metrics['rate_accounts']) {
                return null;
            }
            if ($metrics['rate_accounts'] === 0) {
                if ($metrics['max_evictions_per_window'] !== 0 || $metrics['max_operations_per_second'] !== 0
                    || $metrics['rate_window_earliest_start_at'] !== 0 || $metrics['rate_window_latest_end_at'] !== 0
                    || $metrics['rate_window_min_seconds'] !== 0 || $metrics['rate_window_max_seconds'] !== 0
                    || $metrics['eviction_activity_accounts'] !== 0) {
                    return null;
                }
            } elseif ($metrics['rate_window_min_seconds'] < 1
                || $metrics['rate_window_max_seconds'] < $metrics['rate_window_min_seconds']
                || $metrics['rate_window_earliest_start_at'] > $metrics['rate_window_latest_end_at']) {
                return null;
            }
        }
        if ($hasAuthRateMetrics) {
            $metrics = $decoded['metrics'];
            if ($metrics['auth_rate_accounts'] + $metrics['auth_rate_missing_accounts'] !== $decoded['managed_count']
                || $metrics['auth_failure_accounts'] > $metrics['auth_rate_accounts']) {
                return null;
            }
            if ($metrics['auth_rate_accounts'] === 0) {
                if ($metrics['max_auth_failures_per_window'] !== 0
                    || $metrics['auth_rate_window_earliest_start_at'] !== 0
                    || $metrics['auth_rate_window_latest_end_at'] !== 0
                    || $metrics['auth_rate_window_min_seconds'] !== 0
                    || $metrics['auth_rate_window_max_seconds'] !== 0
                    || $metrics['auth_failure_accounts'] !== 0) {
                    return null;
                }
            } elseif ($metrics['auth_rate_window_min_seconds'] < 1
                || $metrics['auth_rate_window_max_seconds'] < $metrics['auth_rate_window_min_seconds']
                || $metrics['auth_rate_window_earliest_start_at'] > $metrics['auth_rate_window_latest_end_at']) {
                return null;
            }
        }
        return $decoded;
    }

    /** @param list<array{username:string,backup_id?:string}> $targets @return array{success:true,version:1,action:string,partial:bool,requested_count:int,succeeded_count:int,results:list<array<string,mixed>>}|null */
    public function backupFleetBatch(string $action, array $targets): ?array
    {
        if (!in_array($action, ['create', 'restore'], true) || count($targets) < 1 || count($targets) > 2) {
            return null;
        }
        $seen = [];
        $canonicalTargets = [];
        foreach ($targets as $target) {
            if (!is_array($target) || !is_string($target['username'] ?? null)
                || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $target['username']) !== 1
                || isset($seen[$target['username']])) {
                return null;
            }
            $seen[$target['username']] = true;
            if ($action === 'create') {
                if (array_keys($target) !== ['username']) {
                    return null;
                }
                $canonicalTargets[] = $target['username'];
            } else {
                if (array_keys($target) !== ['username', 'backup_id'] && array_keys($target) !== ['backup_id', 'username']) {
                    return null;
                }
                if (!self::validBackupId($target['backup_id'] ?? null)) {
                    return null;
                }
                $canonicalTargets[] = ['backup_id' => $target['backup_id'], 'username' => $target['username']];
            }
        }
        $operation = 'fleet.backup.batch.' . $action;
        $request = json_encode(['operation' => $operation, 'targets' => $canonicalTargets, 'version' => 1],
            JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
        $timeoutSeconds = self::BACKUP_OPERATION_TIMEOUT_SECONDS * count($targets);
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request, $timeoutSeconds)
            : ($this->exchange)($request);
        if (!is_string($response) || $response === '' || strlen($response) > self::MAX_RESPONSE_BYTES
            || !str_ends_with($response, "\n") || substr_count($response, "\n") !== 1) {
            return null;
        }
        try {
            $decoded = json_decode(substr($response, 0, -1), true, 8, JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            return null;
        }
        $keys = is_array($decoded) ? array_keys($decoded) : [];
        sort($keys);
        if ($keys !== ['action', 'partial', 'requested_count', 'results', 'succeeded_count', 'success', 'version']
            || ($decoded['success'] ?? null) !== true || ($decoded['version'] ?? null) !== 1
            || ($decoded['action'] ?? null) !== 'backup.' . $action || !is_bool($decoded['partial'] ?? null)
            || ($decoded['requested_count'] ?? null) !== count($targets) || !is_int($decoded['succeeded_count'] ?? null)
            || !is_array($decoded['results']) || !array_is_list($decoded['results'])
            || count($decoded['results']) !== count($targets)) {
            return null;
        }
        $succeeded = 0;
        foreach ($targets as $index => $target) {
            $item = $decoded['results'][$index];
            if (!is_array($item) || ($item['username'] ?? null) !== $target['username']
                || ($item['action'] ?? null) !== 'backup.' . $action || !is_bool($item['success'] ?? null)) {
                return null;
            }
            $itemKeys = array_keys($item);
            sort($itemKeys);
            if ($item['success']) {
                $succeeded++;
                if (!is_bool($item['audit_logged'] ?? null)) {
                    return null;
                }
                if ($action === 'create') {
                    if ($itemKeys !== ['action', 'audit_logged', 'backup', 'success', 'username']
                        || !self::validBackup($item['backup'] ?? null)) {
                        return null;
                    }
                } elseif ($itemKeys !== ['action', 'audit_logged', 'backup_id', 'safety_backup_id', 'state', 'success', 'username']
                    || ($item['backup_id'] ?? null) !== $target['backup_id']
                    || !self::validBackupId($item['safety_backup_id'] ?? null) || ($item['state'] ?? null) !== 'running') {
                    return null;
                }
            } else {
                $error = $item['error'] ?? null;
                if (!is_string($error) || !in_array($error, [
                    'invalid_request', 'not_authorized', 'operation_failed', 'account_unavailable', 'not_configured',
                    'not_running', 'backup_not_found', 'backup_failed', 'backup_invalid', 'backup_in_progress',
                    'backup_retention_failed', 'backup_storage_unavailable', 'restore_validation_unavailable',
                    'restore_failed', 'restore_rollback_failed', 'rate_limited',
                ], true)) {
                    return null;
                }
                $expected = ['action', 'audit_logged', 'error', 'success', 'username'];
                if (isset($item['safety_backup_id'])) {
                    $expected[] = 'safety_backup_id';
                    if (!self::validBackupId($item['safety_backup_id'])) {
                        return null;
                    }
                }
                if (isset($item['audit_logged'])) {
                    if (!is_bool($item['audit_logged'])) {
                        return null;
                    }
                } else {
                    $expected = array_values(array_diff($expected, ['audit_logged']));
                }
                sort($expected);
                if ($itemKeys !== $expected) {
                    return null;
                }
            }
        }
        if ($decoded['succeeded_count'] !== $succeeded || $decoded['partial'] !== ($succeeded !== count($targets))) {
            return null;
        }
        return $decoded;
    }

    /** @return array{success:bool,version:int,username?:string,action?:string,audit_logged?:bool,state?:string,diagnostics?:array<string,int|string>,error?:string}|null */
    public function diagnoseFleetAccount(string $username): ?array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1) {
            return null;
        }
        $request = json_encode(
            ['operation' => 'fleet.diagnostics', 'username' => $username, 'version' => 1],
            JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
        ) . "\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request, 30)
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
        if (!is_array($decoded) || ($decoded['version'] ?? null) !== 1 || !is_bool($decoded['success'] ?? null)) {
            return null;
        }
        $keys = array_keys($decoded);
        sort($keys);
        if ($decoded['success']) {
            if ($keys !== ['action', 'audit_logged', 'diagnostics', 'state', 'success', 'username', 'version']
                || ($decoded['action'] ?? null) !== 'diagnostics.read' || ($decoded['username'] ?? null) !== $username
                || ($decoded['state'] ?? null) !== 'running' || !is_bool($decoded['audit_logged'] ?? null)
                || !self::validFleetDiagnostics($decoded['diagnostics'] ?? null)) {
                return null;
            }
            return $decoded;
        }
        $allowedKeySets = [
            ['error', 'success', 'version'],
            ['action', 'audit_logged', 'error', 'success', 'username', 'version'],
        ];
        if (!in_array($keys, $allowedKeySets, true)
            || !in_array($decoded['error'] ?? null, [
                'invalid_request', 'not_authorized', 'operation_failed', 'account_unavailable',
                'not_configured', 'not_running', 'diagnostics_unavailable', 'rate_limited',
            ], true)) {
            return null;
        }
        if (isset($decoded['action']) && ($decoded['action'] !== 'diagnostics.read'
            || ($decoded['username'] ?? null) !== $username || !is_bool($decoded['audit_logged'] ?? null))) {
            return null;
        }
        return [
            'success' => false,
            'error' => $decoded['error'],
            'version' => 1,
            ...(isset($decoded['action']) ? [
                'action' => 'diagnostics.read',
                'username' => $username,
                'audit_logged' => $decoded['audit_logged'],
            ] : []),
        ];
    }

    /** @return array{success:bool,version:int,username?:string,action?:string,audit_logged?:bool,finding?:string,state?:string,repair?:string,error?:string}|null */
    public function scanFleetRecovery(string $username): ?array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1) {
            return null;
        }
        $request = json_encode(
            ['operation' => 'fleet.recovery.scan', 'username' => $username, 'version' => 1],
            JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
        ) . "\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request, 30)
            : ($this->exchange)($request);
        $decoded = self::decodeSingleBrokerResponse($response);
        if (!is_array($decoded) || ($decoded['version'] ?? null) !== 1 || !is_bool($decoded['success'] ?? null)) {
            return null;
        }
        $keys = array_keys($decoded);
        sort($keys);
        if ($decoded['success']) {
            $baseKeys = ['action', 'audit_logged', 'finding', 'state', 'success', 'username', 'version'];
            $withRepairKeys = [...$baseKeys, 'repair'];
            sort($withRepairKeys);
            if (($keys !== $baseKeys && $keys !== $withRepairKeys)
                || ($decoded['action'] ?? null) !== 'recovery.scan'
                || ($decoded['username'] ?? null) !== $username || !is_bool($decoded['audit_logged'] ?? null)
                || !in_array($decoded['finding'] ?? null, [
                    'health_probe_failed', 'not_configured', 'service_failed', 'service_healthy',
                    'service_stopped', 'service_transitioning',
                ], true)
                || !in_array($decoded['state'] ?? null, [
                    'failed', 'not_configured', 'running', 'starting', 'stopped', 'stopping',
                ], true)) {
                return null;
            }
            $expected = match ($decoded['finding']) {
                'service_stopped' => ['stopped', 'start'],
                'service_failed' => ['failed', 'start'],
                'service_transitioning' => [in_array($decoded['state'], ['starting', 'stopping'], true) ? $decoded['state'] : '', null],
                'service_healthy', 'health_probe_failed' => ['running', null],
                'not_configured' => ['not_configured', null],
            };
            if ($decoded['state'] !== $expected[0]
                || (isset($decoded['repair']) ? $decoded['repair'] !== $expected[1] : $expected[1] !== null)) {
                return null;
            }
            return $decoded;
        }
        $allowedKeySets = [
            ['error', 'success', 'version'],
            ['action', 'audit_logged', 'error', 'success', 'username', 'version'],
        ];
        if (!in_array($keys, $allowedKeySets, true)
            || !in_array($decoded['error'] ?? null, [
                'account_unavailable', 'instance_unavailable', 'invalid_request', 'not_authorized', 'operation_failed', 'rate_limited',
            ], true)) {
            return null;
        }
        if (isset($decoded['action']) && ($decoded['action'] !== 'recovery.scan'
            || ($decoded['username'] ?? null) !== $username || !is_bool($decoded['audit_logged'] ?? null))) {
            return null;
        }
        return [
            'success' => false,
            'error' => $decoded['error'],
            'version' => 1,
            ...(isset($decoded['action']) ? [
                'action' => 'recovery.scan',
                'username' => $username,
                'audit_logged' => $decoded['audit_logged'],
            ] : []),
        ];
    }

    /** @return array{success:bool,version:int,username?:string,action?:string,audit_logged?:bool,state?:string,error?:string}|null */
    public function repairFleetAccount(string $username, string $repair): ?array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1 || $repair !== 'start') {
            return null;
        }
        $request = json_encode(
            ['repair' => $repair, 'operation' => 'fleet.recovery.repair', 'username' => $username, 'version' => 1],
            JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
        ) . "\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request, 30)
            : ($this->exchange)($request);
        $decoded = self::decodeSingleBrokerResponse($response);
        if (!is_array($decoded) || ($decoded['version'] ?? null) !== 1 || !is_bool($decoded['success'] ?? null)) {
            return null;
        }
        $keys = array_keys($decoded);
        sort($keys);
        if ($decoded['success']) {
            if ($keys !== ['action', 'audit_logged', 'state', 'success', 'username', 'version']
                || ($decoded['action'] ?? null) !== 'recovery.start' || ($decoded['username'] ?? null) !== $username
                || !is_bool($decoded['audit_logged'] ?? null)
                || !in_array($decoded['state'] ?? null, ['running', 'starting'], true)) {
                return null;
            }
            return $decoded;
        }
        $allowedKeySets = [
            ['error', 'success', 'version'],
            ['action', 'audit_logged', 'error', 'success', 'username', 'version'],
        ];
        if (!in_array($keys, $allowedKeySets, true)
            || !in_array($decoded['error'] ?? null, [
                'account_unavailable', 'instance_unavailable', 'invalid_request', 'not_authorized', 'not_configured',
                'operation_in_progress', 'rate_limited', 'repair_not_applicable', 'scan_failed', 'service_failed',
            ], true)) {
            return null;
        }
        if (isset($decoded['action']) && ($decoded['action'] !== 'recovery.start'
            || ($decoded['username'] ?? null) !== $username || !is_bool($decoded['audit_logged'] ?? null))) {
            return null;
        }
        return [
            'success' => false,
            'error' => $decoded['error'],
            'version' => 1,
            ...(isset($decoded['action']) ? [
                'action' => 'recovery.start',
                'username' => $username,
                'audit_logged' => $decoded['audit_logged'],
            ] : []),
        ];
    }

    private static function decodeSingleBrokerResponse(?string $response): ?array
    {
        if (!is_string($response) || $response === '' || strlen($response) > self::MAX_RESPONSE_BYTES
            || !str_ends_with($response, "\n") || substr_count($response, "\n") !== 1) {
            return null;
        }
        try {
            $decoded = json_decode(substr($response, 0, -1), true, 8, JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            return null;
        }
        return is_array($decoded) ? $decoded : null;
    }

    private static function validFleetDiagnostics(mixed $diagnostics): bool
    {
        if (!is_array($diagnostics)) {
            return false;
        }
        $expected = [
            'backend', 'blocked_clients', 'commands_per_second', 'connected_clients', 'database_keys',
            'evicted_keys', 'expired_keys', 'keyspace_hits', 'keyspace_misses', 'maxclients', 'maxmemory_bytes',
            'memory_peak_bytes', 'memory_used_bytes', 'server_version', 'uptime_seconds',
        ];
        $keys = array_keys($diagnostics);
        sort($keys);
        if ($keys !== $expected || !in_array($diagnostics['backend'], ['redis', 'valkey'], true)
            || !is_string($diagnostics['server_version'])
            || preg_match('/\A[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?:[-+][A-Za-z0-9.-]{1,24})?\z/', $diagnostics['server_version']) !== 1) {
            return false;
        }
        foreach ($expected as $field) {
            if (in_array($field, ['backend', 'server_version'], true)) {
                continue;
            }
            if (!is_int($diagnostics[$field]) || $diagnostics[$field] < 0
                || $diagnostics[$field] > self::MAX_DIAGNOSTIC_INTEGER) {
                return false;
            }
        }
        return $diagnostics['memory_peak_bytes'] >= $diagnostics['memory_used_bytes']
            && $diagnostics['connected_clients'] <= $diagnostics['maxclients']
            && $diagnostics['maxclients'] > 0 && $diagnostics['maxclients'] <= 100000;
    }

    /** @return array{success:bool,version:int,action?:string,audit_logged?:bool,state?:string,username?:string,error?:string}|null */
    public function controlFleetAccount(string $username, string $action): ?array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1
            || !in_array($action, ['start', 'stop', 'restart'], true)) {
            return null;
        }
        $request = json_encode(
            ['action' => $action, 'operation' => 'fleet.control', 'username' => $username, 'version' => 1],
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
        $keys = array_keys($decoded);
        sort($keys);
        if ($decoded['success']) {
            if ($keys !== ['action', 'audit_logged', 'state', 'success', 'username', 'version']
                || ($decoded['action'] ?? null) !== $action || ($decoded['username'] ?? null) !== $username
                || !is_bool($decoded['audit_logged'] ?? null)
                || !in_array($decoded['state'] ?? null, ['stopped', 'starting', 'running', 'stopping', 'failed'], true)) {
                return null;
            }
            return $decoded;
        }
        if (!in_array($keys, [['audit_logged', 'error', 'success', 'version'], ['error', 'success', 'version']], true)
            || !in_array($decoded['error'] ?? null, [
                'invalid_request', 'not_authorized', 'operation_failed', 'account_unavailable',
                'instance_unavailable', 'not_configured', 'service_failed', 'rate_limited',
            ], true)) {
            return null;
        }
        if (array_key_exists('audit_logged', $decoded) && !is_bool($decoded['audit_logged'])) {
            return null;
        }
        return [
            'success' => false,
            'error' => $decoded['error'],
            'version' => 1,
            ...(array_key_exists('audit_logged', $decoded) ? ['audit_logged' => $decoded['audit_logged']] : []),
        ];
    }

    /** @return array{success:bool,version:int,username?:string,action?:string,source_backend?:string,target_backend?:string,state?:string,audit_logged?:bool,safety_backup_id?:string,error?:string}|null */
    public function migrateFleetAccount(string $username, string $targetBackend, bool $writesQuiesced): ?array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1
            || $targetBackend !== 'valkey' || !$writesQuiesced) {
            return null;
        }
        $request = json_encode([
            'operation' => 'fleet.migrate',
            'target_backend' => $targetBackend,
            'username' => $username,
            'version' => 1,
            'writes_quiesced' => true,
        ], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request, self::BACKUP_OPERATION_TIMEOUT_SECONDS)
            : ($this->exchange)($request);
        if (!is_string($response) || $response === '' || strlen($response) > self::MAX_RESPONSE_BYTES
            || !str_ends_with($response, "\n") || substr_count($response, "\n") !== 1) {
            return null;
        }
        try {
            $decoded = json_decode(substr($response, 0, -1), true, 5, JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            return null;
        }
        if (!is_array($decoded) || ($decoded['version'] ?? null) !== 1 || !is_bool($decoded['success'] ?? null)) {
            return null;
        }
        $keys = array_keys($decoded);
        sort($keys);
        if ($decoded['success']) {
            if ($keys !== ['action', 'audit_logged', 'safety_backup_id', 'source_backend', 'state', 'success', 'target_backend', 'username', 'version']
                || ($decoded['action'] ?? null) !== 'migration.to-valkey'
                || ($decoded['username'] ?? null) !== $username
                || ($decoded['source_backend'] ?? null) !== 'redis' || ($decoded['target_backend'] ?? null) !== 'valkey'
                || ($decoded['state'] ?? null) !== 'running' || !is_bool($decoded['audit_logged'] ?? null)
                || !self::validBackupId($decoded['safety_backup_id'] ?? null)) {
                return null;
            }
            return $decoded;
        }
        $allowedKeySets = [
            ['error', 'success', 'version'],
            ['action', 'audit_logged', 'error', 'safety_backup_id', 'success', 'username', 'version'],
            ['action', 'audit_logged', 'error', 'success', 'username', 'version'],
        ];
        if (!in_array($keys, $allowedKeySets, true)
            || !in_array($decoded['error'] ?? null, [
                'invalid_request', 'not_authorized', 'operation_failed', 'account_unavailable', 'backend_unavailable',
                'backup_storage_unavailable', 'migration_failed', 'migration_pause_failed', 'migration_recovery_required',
                'migration_rollback_failed', 'migration_state_unavailable', 'migration_timeout', 'migration_unsupported',
                'migration_validation_failed', 'migration_validation_unavailable', 'migration_snapshot_failed',
                'not_configured', 'not_running', 'operation_in_progress', 'rate_limited',
            ], true)) {
            return null;
        }
        if (isset($decoded['action']) && ($decoded['action'] !== 'migration.to-valkey'
            || ($decoded['username'] ?? null) !== $username || !is_bool($decoded['audit_logged'] ?? null))) {
            return null;
        }
        if (isset($decoded['safety_backup_id']) && !self::validBackupId($decoded['safety_backup_id'])) {
            return null;
        }
        return [
            'success' => false,
            'error' => $decoded['error'],
            'version' => 1,
            ...(isset($decoded['action']) ? [
                'action' => 'migration.to-valkey',
                'username' => $username,
                'audit_logged' => $decoded['audit_logged'],
            ] : []),
            ...(isset($decoded['safety_backup_id']) ? ['safety_backup_id' => $decoded['safety_backup_id']] : []),
        ];
    }

    /** @return array{success:bool,version:int,action:string,username:string,audit_logged?:bool,backup?:array{id:string,created_at:int,size_bytes:int},backup_id?:string,safety_backup_id?:string,state?:string,error?:string}|null */
    public function backupFleetAccount(string $username, string $action, ?string $backupId = null): ?array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1
            || !in_array($action, ['create', 'restore'], true)
            || ($action === 'create' && $backupId !== null)
            || ($action === 'restore' && !self::validBackupId($backupId))) {
            return null;
        }
        $operation = 'fleet.backup.' . $action;
        $payload = $action === 'create'
            ? ['operation' => $operation, 'username' => $username, 'version' => 1]
            : ['backup_id' => $backupId, 'operation' => $operation, 'username' => $username, 'version' => 1];
        $request = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request, self::BACKUP_OPERATION_TIMEOUT_SECONDS)
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
        if (!is_array($decoded) || ($decoded['version'] ?? null) !== 1 || !is_bool($decoded['success'] ?? null)) {
            return null;
        }
        $expectedAction = 'backup.' . $action;
        $keys = array_keys($decoded);
        sort($keys);
        if (!$decoded['success'] && $keys === ['error', 'success', 'version']
            && in_array($decoded['error'] ?? null, ['invalid_request', 'not_authorized', 'operation_failed', 'rate_limited'], true)) {
            return [
                'action' => $expectedAction,
                'error' => $decoded['error'],
                'success' => false,
                'username' => $username,
                'version' => 1,
            ];
        }
        if ($decoded['success']) {
            if (($decoded['action'] ?? null) !== $expectedAction || ($decoded['username'] ?? null) !== $username
                || !is_bool($decoded['audit_logged'] ?? null)) {
                return null;
            }
            if ($action === 'create') {
                if ($keys !== ['action', 'audit_logged', 'backup', 'success', 'username', 'version']
                    || !self::validBackup($decoded['backup'] ?? null)) {
                    return null;
                }
            } elseif ($keys !== ['action', 'audit_logged', 'backup_id', 'safety_backup_id', 'state', 'success', 'username', 'version']
                || ($decoded['backup_id'] ?? null) !== $backupId
                || !self::validBackupId($decoded['safety_backup_id'] ?? null)
                || ($decoded['state'] ?? null) !== 'running') {
                return null;
            }
            return $decoded;
        }

        $allowedFailures = [
            ['action', 'audit_logged', 'error', 'success', 'username', 'version'],
            ['action', 'audit_logged', 'error', 'safety_backup_id', 'success', 'username', 'version'],
        ];
        $withoutAudit = [
            ['action', 'error', 'success', 'username', 'version'],
            ['action', 'error', 'safety_backup_id', 'success', 'username', 'version'],
        ];
        if (!in_array($keys, [...$allowedFailures, ...$withoutAudit], true)
            || ($decoded['action'] ?? null) !== $expectedAction || ($decoded['username'] ?? null) !== $username
            || !in_array($decoded['error'] ?? null, [
                'invalid_request', 'not_authorized', 'operation_failed', 'account_unavailable', 'not_configured',
                'not_running', 'backup_not_found', 'backup_failed', 'backup_invalid', 'backup_in_progress',
                'backup_retention_failed', 'backup_storage_unavailable', 'restore_validation_unavailable',
                'restore_failed', 'restore_rollback_failed', 'rate_limited',
            ], true)) {
            return null;
        }
        if (array_key_exists('audit_logged', $decoded) && !is_bool($decoded['audit_logged'])) {
            return null;
        }
        if (array_key_exists('safety_backup_id', $decoded) && !self::validBackupId($decoded['safety_backup_id'])) {
            return null;
        }
        return $decoded;
    }

    private function exchangeWithLocalBroker(string $request, int $timeoutSeconds = 35): ?string
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

        stream_set_timeout($stream, $timeoutSeconds);
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
