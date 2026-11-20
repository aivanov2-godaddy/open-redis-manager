<?php
declare(strict_types=1);

namespace Orm\Backend;

/** Root-owned provider policy for package limits and global defaults for future instances. */
final class ProviderPolicyStore
{
    private const PATH = '/etc/orm-provider-policy.json';
    private const MAX_BYTES = 262144;
    private const MAX_LOGO_BYTES = 32768;

    public function __construct(
        private readonly string $path = self::PATH,
        private readonly ?int $expectedOwnerUid = null,
    ) {
    }

    /** @return array{version:int,mode:string,exposure:string,default:array{enabled:bool,max_memory_mib:int,backup_retention:int,max_clients:int,max_databases:int},instance_defaults:array{memory_mib:int,maxmemory_policy:string,databases:int,metrics_history_retention_days:int},packages:array<string,array{enabled:bool,max_memory_mib:int,backup_retention:int,max_clients:int,max_databases:int}>,resellers:array<string,array{max_instances:int,max_memory_mib:int}>,branding:array{product_name:string,logo_png_base64:string,support_url:string,preset:string,primary_color:string,secondary_color:string,surface_color:string,text_color:string,footer_visible:bool}}|null */
    public function load(): ?array
    {
        if (!$this->authorized()) {
            return null;
        }
        $directory = dirname($this->path);
        $directoryStat = @lstat($directory);
        $owner = $this->ownerUid();
        if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
            || $directoryStat['uid'] !== $owner || ($directoryStat['mode'] & 0022) !== 0) {
            return null;
        }
        $stat = @lstat($this->path);
        if ($stat === false && !file_exists($this->path) && !is_link($this->path)) {
            return self::defaults();
        }
        if (!is_array($stat) || (($stat['mode'] & 0170000) !== 0100000)
            || $stat['uid'] !== $owner || $stat['nlink'] !== 1 || ($stat['mode'] & 0777) !== 0600
            || $stat['size'] > self::MAX_BYTES) {
            return null;
        }
        $handle = @fopen($this->path, 'rb');
        if (!is_resource($handle)) {
            return null;
        }
        $openedStat = fstat($handle);
        $content = stream_get_contents($handle, self::MAX_BYTES + 1);
        fclose($handle);
        if (!is_array($openedStat) || $openedStat['dev'] !== $stat['dev'] || $openedStat['ino'] !== $stat['ino']
            || !is_string($content) || strlen($content) > self::MAX_BYTES) {
            return null;
        }
        try {
            $decoded = json_decode($content, true, 8, JSON_THROW_ON_ERROR);
        } catch (\Throwable) {
            return null;
        }
        return self::normalize($decoded);
    }

    /** @param mixed $policy */
    public function save(mixed $policy): bool
    {
        if (!$this->authorized()) {
            return false;
        }
        $normalized = self::normalize($policy);
        if ($normalized === null) {
            return false;
        }
        $directory = dirname($this->path);
        $directoryStat = @lstat($directory);
        $owner = $this->ownerUid();
        if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
            || $directoryStat['uid'] !== $owner || ($directoryStat['mode'] & 0022) !== 0) {
            return false;
        }
        $existing = @lstat($this->path);
        if ($existing !== false && (!is_array($existing) || (($existing['mode'] & 0170000) !== 0100000)
            || $existing['uid'] !== $owner || $existing['nlink'] !== 1 || ($existing['mode'] & 0777) !== 0600)) {
            return false;
        }
        try {
            $temporary = $directory . '/.orm-provider-policy-' . bin2hex(random_bytes(12));
            $handle = @fopen($temporary, 'xb');
            if (!is_resource($handle)) {
                return false;
            }
            $content = json_encode($normalized, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
            $written = fwrite($handle, $content);
            $flushed = fflush($handle);
            $synced = function_exists('fsync') ? fsync($handle) : true;
            $openedStat = fstat($handle);
            fclose($handle);
            if ($written !== strlen($content) || !$flushed || !$synced || !is_array($openedStat)
                || $openedStat['uid'] !== $owner || !@chmod($temporary, 0600)) {
                @unlink($temporary);
                return false;
            }
            if (!@rename($temporary, $this->path)) {
                @unlink($temporary);
                return false;
            }
            return true;
        } catch (\Throwable) {
            return false;
        }
    }

    /** @return array{version:int,mode:string,exposure:string,default:array{enabled:bool,max_memory_mib:int,backup_retention:int,max_clients:int,max_databases:int},instance_defaults:array{memory_mib:int,maxmemory_policy:string,databases:int,metrics_history_retention_days:int},packages:array{},resellers:array{},branding:array{product_name:string,logo_png_base64:string,support_url:string,preset:string,primary_color:string,secondary_color:string,surface_color:string,text_color:string,footer_visible:bool}} */
    public static function defaults(): array
    {
        return [
            'version' => 5,
            'mode' => 'report-only',
            'exposure' => 'simple',
            'default' => [
                'enabled' => true,
                'max_memory_mib' => 64,
                'backup_retention' => 3,
                'max_clients' => 100,
                'max_databases' => 16,
            ],
            'instance_defaults' => [
                'memory_mib' => 64,
                'maxmemory_policy' => 'allkeys-lru',
                'databases' => 16,
                'metrics_history_retention_days' => 30,
            ],
            'packages' => [],
            'resellers' => [],
            'branding' => self::defaultBranding(),
        ];
    }

    /** @param mixed $policy */
    public static function normalize(mixed $policy): ?array
    {
        if (!is_array($policy) || array_is_list($policy)) {
            return null;
        }
        $keys = array_keys($policy);
        sort($keys);
        if (!in_array($policy['version'] ?? null, [1, 2, 3, 4, 5], true)
            || ($policy['version'] === 1 && $keys !== ['default', 'mode', 'packages', 'version'])
            || ($policy['version'] === 2 && $keys !== ['default', 'exposure', 'mode', 'packages', 'resellers', 'version'])
            || ($policy['version'] === 3 && $keys !== ['branding', 'default', 'exposure', 'mode', 'packages', 'resellers', 'version'])
            || (in_array($policy['version'], [4, 5], true) && $keys !== ['branding', 'default', 'exposure', 'instance_defaults', 'mode', 'packages', 'resellers', 'version'])
            || ($policy['version'] === 1 && !in_array($policy['mode'] ?? null, ['report-only', 'enforce'], true))
            || ($policy['version'] === 2 && (!in_array($policy['mode'] ?? null, ['report-only', 'warn', 'enforce'], true)
                || !in_array($policy['exposure'] ?? null, ['simple', 'developer', 'advanced'], true)
                || !is_array($policy['resellers'] ?? null)
                || array_is_list($policy['resellers']) && $policy['resellers'] !== []
                || count($policy['resellers']) > 1000))
            || (in_array($policy['version'], [3, 4, 5], true) && (!in_array($policy['mode'] ?? null, ['report-only', 'warn', 'enforce'], true)
                || !in_array($policy['exposure'] ?? null, ['simple', 'developer', 'advanced'], true)
                || !is_array($policy['resellers'] ?? null)
                || array_is_list($policy['resellers']) && $policy['resellers'] !== []
                || count($policy['resellers']) > 1000))
            || !is_array($policy['packages']) || array_is_list($policy['packages']) && $policy['packages'] !== []
            || count($policy['packages']) > 1000) {
            return null;
        }
        $default = self::normalizeLimits($policy['default'], $policy['version'] < 5);
        if ($default === null) {
            return null;
        }
        $instanceDefaults = self::normalizeInstanceDefaults($policy['version'] >= 4
            ? ($policy['instance_defaults'] ?? null)
            : self::defaults()['instance_defaults']);
        if ($instanceDefaults === null) {
            return null;
        }
        $packages = [];
        foreach ($policy['packages'] as $name => $limits) {
            if (!is_string($name) || $name === 'default'
                || preg_match('/\A[a-zA-Z0-9_.-]{1,64}\z/', $name) !== 1) {
                return null;
            }
            $normalizedLimits = self::normalizeLimits($limits, $policy['version'] < 5);
            if ($normalizedLimits === null) {
                return null;
            }
            $packages[$name] = $normalizedLimits;
        }
        ksort($packages, SORT_STRING);
        $resellers = [];
        if ($policy['version'] >= 2) {
            foreach ($policy['resellers'] as $owner => $limits) {
                if (!is_string($owner) || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $owner) !== 1
                    || !is_array($limits) || array_is_list($limits)) {
                    return null;
                }
                $ruleKeys = array_keys($limits);
                sort($ruleKeys);
                if ($ruleKeys !== ['max_instances', 'max_memory_mib']
                    || !is_int($limits['max_instances']) || $limits['max_instances'] < 0 || $limits['max_instances'] > 100000
                    || !is_int($limits['max_memory_mib']) || $limits['max_memory_mib'] < 0 || $limits['max_memory_mib'] > 1000000) {
                    return null;
                }
                $resellers[$owner] = [
                    'max_instances' => $limits['max_instances'],
                    'max_memory_mib' => $limits['max_memory_mib'],
                ];
            }
        }
        ksort($resellers, SORT_STRING);
        $branding = self::normalizeBranding($policy['version'] >= 3 ? ($policy['branding'] ?? null) : self::defaultBranding());
        if ($branding === null) {
            return null;
        }
        return [
            'version' => 5,
            'mode' => $policy['version'] === 1 && $policy['mode'] === 'report-only' ? 'warn' : $policy['mode'],
            'exposure' => $policy['version'] >= 2 ? $policy['exposure'] : 'simple',
            'default' => $default,
            'instance_defaults' => $instanceDefaults,
            'packages' => $packages,
            'resellers' => $resellers,
            'branding' => $branding,
        ];
    }

    /** @return array{product_name:string,logo_png_base64:string,support_url:string,primary_color:string,secondary_color:string,footer_visible:bool} */
    public static function defaultBranding(): array
    {
        return [
            'product_name' => 'Open Redis Manager',
            'logo_png_base64' => '',
            'support_url' => '',
            'preset' => 'orm',
            'primary_color' => '#C92319',
            'secondary_color' => '#A91F18',
            'surface_color' => '#FFFFFF',
            'text_color' => '#172536',
            'footer_visible' => true,
        ];
    }

    /** @param mixed $branding @return array{product_name:string,logo_png_base64:string,support_url:string,preset:string,primary_color:string,secondary_color:string,surface_color:string,text_color:string,footer_visible:bool}|null */
    public static function normalizeBranding(mixed $branding): ?array
    {
        if (!is_array($branding) || array_is_list($branding)) {
            return null;
        }
        $keys = array_keys($branding);
        sort($keys);
        if ($keys !== ['footer_visible', 'logo_png_base64', 'preset', 'primary_color', 'product_name', 'secondary_color', 'support_url', 'surface_color', 'text_color']
            || !is_string($branding['product_name'])
            || preg_match('/\\A[A-Za-z0-9][A-Za-z0-9 .&()+\\/_-]{0,47}\\z/', $branding['product_name']) !== 1
            || !is_string($branding['support_url']) || !self::validSupportUrl($branding['support_url'])
            || !is_string($branding['preset']) || !in_array($branding['preset'], ['custom', 'orm', 'underhost', 'redis', 'valkey'], true)
            || !is_string($branding['primary_color']) || !self::isBrandHexColor($branding['primary_color'])
            || !is_string($branding['secondary_color']) || !self::isBrandHexColor($branding['secondary_color'])
            || !is_string($branding['surface_color']) || !self::isBrandHexColor($branding['surface_color'])
            || !is_string($branding['text_color']) || !self::isBrandHexColor($branding['text_color'])
            || !self::hasContrast($branding['primary_color'], '#FFFFFF')
            || !self::hasContrast($branding['primary_color'], $branding['surface_color'])
            || !self::hasContrast($branding['secondary_color'], $branding['surface_color'])
            || !self::hasContrast($branding['text_color'], '#FFFFFF')
            || !self::hasContrast($branding['text_color'], $branding['surface_color'])
            || !is_bool($branding['footer_visible']) || !is_string($branding['logo_png_base64'])) {
            return null;
        }
        $logo = $branding['logo_png_base64'];
        if ($logo !== '') {
            if (strlen($logo) > (int) ceil(self::MAX_LOGO_BYTES * 4 / 3) + 4
                || preg_match('/\\A(?:[A-Za-z0-9+\\/]{4})*(?:[A-Za-z0-9+\\/]{2}==|[A-Za-z0-9+\\/]{3}=)?\\z/', $logo) !== 1) {
                return null;
            }
            $bytes = base64_decode($logo, true);
            if (!is_string($bytes) || strlen($bytes) > self::MAX_LOGO_BYTES || base64_encode($bytes) !== $logo) {
                return null;
            }
            $image = getimagesizefromstring($bytes);
            if (!is_array($image) || ($image['mime'] ?? null) !== 'image/png'
                || $image[0] < 16 || $image[0] > 512 || $image[1] < 16 || $image[1] > 256) {
                return null;
            }
        }
        return [
            'product_name' => $branding['product_name'],
            'logo_png_base64' => $logo,
            'support_url' => $branding['support_url'],
            'preset' => $branding['preset'],
            'primary_color' => strtoupper($branding['primary_color']),
            'secondary_color' => strtoupper($branding['secondary_color']),
            'surface_color' => strtoupper($branding['surface_color']),
            'text_color' => strtoupper($branding['text_color']),
            'footer_visible' => $branding['footer_visible'],
        ];
    }

    private static function validSupportUrl(string $url): bool
    {
        if ($url === '') {
            return true;
        }
        if (strlen($url) > 200 || preg_match('~\\Ahttps://[^\\s/?#@]+(?::[0-9]{1,5})?(?:/[A-Za-z0-9._\~!$&\'()*+,;=:@%/-]*)?\\z~', $url) !== 1) {
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

    private static function isBrandHexColor(string $color): bool
    {
        return preg_match('/\\A#[A-Fa-f0-9]{6}\\z/', $color) === 1;
    }

    private static function hasContrast(string $foreground, string $background): bool
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

    /** @param mixed $limits */
    private static function normalizeLimits(mixed $limits, bool $legacy = false): ?array
    {
        if (!is_array($limits) || array_is_list($limits)) {
            return null;
        }
        $keys = array_keys($limits);
        sort($keys);
        if ($legacy) {
            if ($keys !== ['backup_retention', 'enabled', 'max_memory_mib']) {
                return null;
            }
            $limits['max_clients'] = 100;
            $limits['max_databases'] = 16;
            $keys = ['backup_retention', 'enabled', 'max_clients', 'max_databases', 'max_memory_mib'];
        }
        if ($keys !== ['backup_retention', 'enabled', 'max_clients', 'max_databases', 'max_memory_mib'] || !is_bool($limits['enabled'])
            || !is_int($limits['max_memory_mib']) || $limits['max_memory_mib'] < 8 || $limits['max_memory_mib'] > 64
            || !is_int($limits['backup_retention']) || $limits['backup_retention'] < 2 || $limits['backup_retention'] > 3
            || !is_int($limits['max_clients']) || $limits['max_clients'] < 10 || $limits['max_clients'] > 100
            || !is_int($limits['max_databases']) || $limits['max_databases'] < 1 || $limits['max_databases'] > 16) {
            return null;
        }
        return [
            'enabled' => $limits['enabled'],
            'max_memory_mib' => $limits['max_memory_mib'],
            'backup_retention' => $limits['backup_retention'],
            'max_clients' => $limits['max_clients'],
            'max_databases' => $limits['max_databases'],
        ];
    }

    /** @param mixed $defaults @return array{memory_mib:int,maxmemory_policy:string,databases:int,metrics_history_retention_days:int}|null */
    private static function normalizeInstanceDefaults(mixed $defaults): ?array
    {
        if (!is_array($defaults) || array_is_list($defaults)) {
            return null;
        }
        $keys = array_keys($defaults);
        sort($keys);
        if ($keys !== ['databases', 'maxmemory_policy', 'memory_mib', 'metrics_history_retention_days']
            || !is_int($defaults['memory_mib']) || $defaults['memory_mib'] < 8 || $defaults['memory_mib'] > 64
            || !is_string($defaults['maxmemory_policy'])
            || !in_array($defaults['maxmemory_policy'], [
                'allkeys-lru', 'allkeys-lfu', 'allkeys-random', 'volatile-lru',
                'volatile-lfu', 'volatile-random', 'volatile-ttl', 'noeviction',
            ], true)
            || !is_int($defaults['databases']) || $defaults['databases'] < 1 || $defaults['databases'] > 16
            || !is_int($defaults['metrics_history_retention_days'])
            || $defaults['metrics_history_retention_days'] < 7 || $defaults['metrics_history_retention_days'] > 90) {
            return null;
        }
        return [
            'memory_mib' => $defaults['memory_mib'],
            'maxmemory_policy' => $defaults['maxmemory_policy'],
            'databases' => $defaults['databases'],
            'metrics_history_retention_days' => $defaults['metrics_history_retention_days'],
        ];
    }

    private function authorized(): bool
    {
        return function_exists('posix_geteuid') && posix_geteuid() === $this->ownerUid();
    }

    private function ownerUid(): int
    {
        return $this->expectedOwnerUid ?? 0;
    }
}
