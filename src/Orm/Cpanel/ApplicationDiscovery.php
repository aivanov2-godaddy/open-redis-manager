<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** Read-only, bounded marker discovery for the authenticated cPanel account. */
final class ApplicationDiscovery
{
    private const MAX_ROOTS = 32;
    private const MAX_API_NODES = 512;
    private const MAX_API_DEPTH = 8;
    private const MAX_SCAN_MILLISECONDS = 150;

    /**
     * Each application requires multiple fixed markers. Marker files are only
     * lstat'ed; this class never opens or reads application files.
     * @var array<string, array<string, string>>
     */
    private const APPLICATION_MARKERS = [
        'WordPress' => [
            'wp-includes/version.php' => 'file',
            'wp-admin/admin.php' => 'file',
            'wp-content/plugins' => 'directory',
        ],
        'Laravel' => [
            'artisan' => 'file',
            'bootstrap/app.php' => 'file',
        ],
        'Drupal' => [
            'core/lib/Drupal.php' => 'file',
            'sites/default/settings.php' => 'file',
        ],
        'Joomla' => [
            'administrator/manifests/files/joomla.xml' => 'file',
            'configuration.php' => 'file',
        ],
        'Magento / Adobe Commerce' => [
            'bin/magento' => 'file',
            'app/etc/di.xml' => 'file',
        ],
        'Symfony' => [
            'bin/console' => 'file',
            'symfony.lock' => 'file',
        ],
    ];

    /**
     * Query only the authenticated account's cPanel APIs and return fixed app
     * names. A mismatched execution user, failed API call, or malformed response
     * fails closed without exposing cPanel errors or filesystem paths.
     *
     * @return array{available:bool,applications:list<string>,roots_inspected:int,truncated:bool}
     */
    public static function fromLiveApi(object $liveApi, string $username): array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1
            || !is_callable([$liveApi, 'uapi'])
            || !function_exists('posix_geteuid')
            || !function_exists('posix_getpwuid')) {
            return self::unavailable();
        }

        $executionAccount = @posix_getpwuid(posix_geteuid());
        if (!is_array($executionAccount) || ($executionAccount['name'] ?? null) !== $username) {
            return self::unavailable();
        }

        try {
            $homeResponse = $liveApi->uapi('Variables', 'get_user_information', ['name' => 'homedir']);
            $domainsResponse = $liveApi->uapi('DomainInfo', 'domains_data', ['format' => 'hash']);
        } catch (\Throwable) {
            return self::unavailable();
        }

        $homeData = self::successfulData($homeResponse);
        $domainsData = self::successfulData($domainsResponse);
        $home = is_array($homeData) ? ($homeData['homedir'] ?? null) : null;
        if (!is_string($home) || !is_array($domainsData)) {
            return self::unavailable();
        }

        $roots = [];
        $visited = 0;
        $truncated = false;
        self::collectDocumentRoots($domainsData, $roots, $visited, 0, $truncated);
        $result = self::scan($home, $roots);
        $result['truncated'] = $result['truncated'] || $truncated;
        return $result;
    }

    /**
     * Scan roots supplied by trusted cPanel metadata. No domain names or paths
     * are returned to callers.
     *
     * @param list<string> $documentRoots
     * @return array{available:bool,applications:list<string>,roots_inspected:int,truncated:bool}
     */
    public static function scan(string $home, array $documentRoots): array
    {
        $canonicalHome = realpath($home);
        if (!is_string($canonicalHome) || !is_dir($canonicalHome)) {
            return self::unavailable();
        }
        $homeStat = @lstat($canonicalHome);
        if (!is_array($homeStat) || !self::isDirectory($homeStat)) {
            return self::unavailable();
        }

        $homeNormalized = self::normalizeSeparators(rtrim($canonicalHome, '/\\'));
        $reportedHome = self::normalizeSeparators(rtrim($home, '/\\'));
        if (!self::isAbsolutePath($homeNormalized)) {
            return self::unavailable();
        }
        $deadline = hrtime(true) + (self::MAX_SCAN_MILLISECONDS * 1_000_000);
        $roots = [];
        $truncated = count($documentRoots) > self::MAX_ROOTS;
        foreach (array_slice($documentRoots, 0, self::MAX_ROOTS) as $documentRoot) {
            if (hrtime(true) > $deadline) {
                $truncated = true;
                break;
            }
            if (!is_string($documentRoot) || strlen($documentRoot) > 4096
                || preg_match('/[\x00-\x1f\x7f]/', $documentRoot) === 1) {
                continue;
            }
            $relative = self::relativeToHome($reportedHome, $homeNormalized, $documentRoot);
            if ($relative === null) {
                continue;
            }
            $root = self::directoryWithoutSymlinks($homeNormalized, $relative, $deadline);
            if (hrtime(true) > $deadline) {
                $truncated = true;
                break;
            }
            if ($root !== null) {
                $roots[$root] = true;
            }
        }

        $roots = array_keys($roots);
        $found = [];
        $rootsInspected = 0;

        foreach ($roots as $root) {
            $rootsInspected++;
            foreach (self::APPLICATION_MARKERS as $application => $markers) {
                $matched = true;
                foreach ($markers as $marker => $type) {
                    if (hrtime(true) > $deadline) {
                        $truncated = true;
                        break 3;
                    }
                    if (!self::hasMarker($root, $marker, $type, $deadline)) {
                        if (hrtime(true) > $deadline) {
                            $truncated = true;
                            break 3;
                        }
                        $matched = false;
                        break;
                    }
                }
                if ($matched) {
                    $found[$application] = true;
                }
            }
        }

        return [
            'available' => true,
            'applications' => array_values(array_keys($found)),
            'roots_inspected' => $rootsInspected,
            'truncated' => $truncated,
        ];
    }

    /** @return array<string, mixed>|null */
    private static function successfulData(mixed $response): ?array
    {
        if (!is_array($response)) {
            return null;
        }
        $result = $response['cpanelresult']['result'] ?? null;
        if (!is_array($result) || !in_array($result['status'] ?? null, [1, '1'], true)) {
            return null;
        }
        $data = $result['data'] ?? null;
        return is_array($data) ? $data : null;
    }

    /** @param list<string> $roots */
    private static function collectDocumentRoots(
        array $node,
        array &$roots,
        int &$visited,
        int $depth,
        bool &$truncated
    ): void {
        if ($depth > self::MAX_API_DEPTH || ++$visited > self::MAX_API_NODES) {
            $truncated = true;
            return;
        }

        foreach ($node as $key => $value) {
            if (is_string($key) && strtolower($key) === 'documentroot' && is_string($value)) {
                $roots[] = $value;
                continue;
            }
            if (is_array($value)) {
                self::collectDocumentRoots($value, $roots, $visited, $depth + 1, $truncated);
            }
            if ($truncated) {
                return;
            }
        }
    }

    private static function relativeToHome(string $reportedHome, string $canonicalHome, string $documentRoot): ?string
    {
        $root = self::normalizeSeparators($documentRoot);
        foreach (array_unique([$reportedHome, $canonicalHome]) as $home) {
            $homePrefix = $home . '/';
            if (self::samePath($root, $home)) {
                return '';
            }
            if (self::startsWithPath($root, $homePrefix)) {
                $relative = substr($root, strlen($homePrefix));
                break;
            }
        }
        if (!isset($relative)) {
            if (self::isAbsolutePath($root)) {
                return null;
            }
            $relative = $root;
        }

        $parts = explode('/', $relative);
        if (count($parts) > 32) {
            return null;
        }
        foreach ($parts as $part) {
            if ($part === '' || $part === '.' || $part === '..') {
                return null;
            }
        }
        return $relative;
    }

    private static function directoryWithoutSymlinks(string $home, string $relative, int $deadline): ?string
    {
        $current = $home;
        if ($relative === '') {
            return $current;
        }
        foreach (explode('/', $relative) as $part) {
            if (hrtime(true) > $deadline) {
                return null;
            }
            $current .= DIRECTORY_SEPARATOR . $part;
            $stat = @lstat($current);
            if (!is_array($stat) || !self::isDirectory($stat)) {
                return null;
            }
        }
        return $current;
    }

    private static function hasMarker(string $root, string $marker, string $expectedType, int $deadline): bool
    {
        $parts = explode('/', $marker);
        $current = $root;
        $last = count($parts) - 1;
        foreach ($parts as $index => $part) {
            if (hrtime(true) > $deadline) {
                return false;
            }
            $current .= DIRECTORY_SEPARATOR . $part;
            $stat = @lstat($current);
            if (!is_array($stat)) {
                return false;
            }
            if ($index < $last && !self::isDirectory($stat)) {
                return false;
            }
            if ($index === $last) {
                return $expectedType === 'directory'
                    ? self::isDirectory($stat)
                    : self::isRegularFile($stat);
            }
        }
        return false;
    }

    /** @param array<string, int> $stat */
    private static function isDirectory(array $stat): bool
    {
        return (($stat['mode'] ?? 0) & 0170000) === 0040000;
    }

    /** @param array<string, int> $stat */
    private static function isRegularFile(array $stat): bool
    {
        return (($stat['mode'] ?? 0) & 0170000) === 0100000;
    }

    private static function normalizeSeparators(string $path): string
    {
        return str_replace('\\', '/', $path);
    }

    private static function isAbsolutePath(string $path): bool
    {
        return str_starts_with($path, '/')
            || preg_match('/\A[A-Za-z]:\//', $path) === 1;
    }

    private static function startsWithPath(string $path, string $prefix): bool
    {
        return DIRECTORY_SEPARATOR === '\\'
            ? strncasecmp($path, $prefix, strlen($prefix)) === 0
            : str_starts_with($path, $prefix);
    }

    private static function samePath(string $left, string $right): bool
    {
        return DIRECTORY_SEPARATOR === '\\' ? strcasecmp($left, $right) === 0 : $left === $right;
    }

    /** @return array{available:bool,applications:list<string>,roots_inspected:int,truncated:bool} */
    private static function unavailable(): array
    {
        return ['available' => false, 'applications' => [], 'roots_inspected' => 0, 'truncated' => false];
    }
}
