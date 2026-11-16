<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Cpanel/ApplicationDiscovery.php';

use Orm\Cpanel\ApplicationDiscovery;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    $checks++;
    if (!$condition) {
        throw new RuntimeException($message);
    }
};
$base = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'orm-app-discovery-' . bin2hex(random_bytes(8));
$home = $base . DIRECTORY_SEPARATOR . 'home';
$docroot = $home . DIRECTORY_SEPARATOR . 'public_html';
$apiRoot = $home . DIRECTORY_SEPARATOR . 'api-public';
$outside = $base . DIRECTORY_SEPARATOR . 'outside';
$mkdir = static function (string $path): void {
    if (!mkdir($path, 0700, true) && !is_dir($path)) {
        throw new RuntimeException('Unable to create a discovery test directory.');
    }
};
$file = static function (string $path): void {
    $parent = dirname($path);
    if (!is_dir($parent) && !mkdir($parent, 0700, true) && !is_dir($parent)) {
        throw new RuntimeException('Unable to create a discovery test marker directory.');
    }
    if (file_put_contents($path, 'marker test fixture') === false) {
        throw new RuntimeException('Unable to create a discovery test marker.');
    }
};
$removeTree = static function (string $path) use (&$removeTree): void {
    if (is_link($path) || is_file($path)) {
        @unlink($path);
        return;
    }
    if (!is_dir($path)) {
        return;
    }
    $entries = scandir($path);
    if (is_array($entries)) {
        foreach ($entries as $entry) {
            if ($entry !== '.' && $entry !== '..') {
                $removeTree($path . DIRECTORY_SEPARATOR . $entry);
            }
        }
    }
    @rmdir($path);
};

try {
    $mkdir($home);
    $mkdir($docroot);
    $mkdir($outside);

    $file($docroot . '/wp-includes/version.php');
    $file($docroot . '/wp-admin/admin.php');
    $mkdir($docroot . '/wp-content/plugins');
    $file($docroot . '/wp-config.php');
    file_put_contents($docroot . '/wp-config.php', 'secret-fixture-must-not-be-returned');
    $file($apiRoot . '/wp-includes/version.php');
    $file($apiRoot . '/wp-admin/admin.php');
    $mkdir($apiRoot . '/wp-content/plugins');

    $found = ApplicationDiscovery::scan($home, [$docroot]);
    $assert($found === ['available' => true, 'applications' => ['WordPress'], 'roots_inspected' => 1, 'truncated' => false], 'Detect WordPress from fixed markers only.');
    $assert(!str_contains(json_encode($found, JSON_THROW_ON_ERROR), 'secret-fixture'), 'Never return application configuration contents.');

    $traversal = ApplicationDiscovery::scan($home, [$home . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . 'outside']);
    $assert($traversal['applications'] === [], 'Reject a document root containing parent traversal.');
    $external = ApplicationDiscovery::scan($home, [$outside]);
    $assert($external['applications'] === [], 'Reject roots outside the authenticated account home.');
    $missing = ApplicationDiscovery::scan($home, [$home . DIRECTORY_SEPARATOR . 'missing']);
    $assert($missing['available'] && $missing['applications'] === [], 'Ignore inaccessible or missing roots without failing the page.');
    $deepRoot = $home . DIRECTORY_SEPARATOR . implode(DIRECTORY_SEPARATOR, array_fill(0, 33, 'nested'));
    $tooDeep = ApplicationDiscovery::scan($home, [$deepRoot]);
    $assert($tooDeep['roots_inspected'] === 0, 'Reject roots that exceed the fixed path-depth limit.');

    $mkdir($outside . '/wp-includes');
    $file($outside . '/wp-includes/version.php');
    $file($outside . '/wp-admin/admin.php');
    $mkdir($outside . '/wp-content/plugins');
    $linkMade = @symlink($outside, $home . DIRECTORY_SEPARATOR . 'linked-root');
    if ($linkMade) {
        $linkedRoot = ApplicationDiscovery::scan($home, [$home . DIRECTORY_SEPARATOR . 'linked-root']);
        $assert($linkedRoot['applications'] === [], 'Do not follow a document-root symlink.');
    }
    $mkdir($docroot . '/wp-includes-link-parent');
    @unlink($docroot . '/wp-includes/version.php');
    @rmdir($docroot . '/wp-includes');
    $parentLinkMade = @symlink($outside . '/wp-includes', $docroot . '/wp-includes');
    if ($parentLinkMade) {
        $nestedLink = ApplicationDiscovery::scan($home, [$docroot]);
        $assert($nestedLink['applications'] === [], 'Do not follow a symlink in a marker path.');
    }

    $manyRoots = [];
    for ($index = 0; $index < 33; $index++) {
        $path = $home . DIRECTORY_SEPARATOR . 'site-' . $index;
        $mkdir($path);
        $manyRoots[] = $path;
    }
    $bounded = ApplicationDiscovery::scan($home, $manyRoots);
    $assert($bounded['truncated'] === true && $bounded['roots_inspected'] <= 32, 'Report and enforce the fixed document-root limit.');

    if (function_exists('posix_geteuid') && function_exists('posix_getpwuid')) {
        $currentUser = @posix_getpwuid(posix_geteuid());
        $username = is_array($currentUser) ? ($currentUser['name'] ?? null) : null;
        if (is_string($username) && preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) === 1) {
            $fakeApi = new class($home, $apiRoot) {
                public function __construct(private string $home, private string $docroot) {}
                public function uapi(string $module, string $function, array $parameters): array
                {
                    if ($module === 'Variables' && $function === 'get_user_information' && $parameters === ['name' => 'homedir']) {
                        return ['cpanelresult' => ['result' => ['status' => 1, 'data' => ['homedir' => $this->home]]]];
                    }
                    if ($module === 'DomainInfo' && $function === 'domains_data' && $parameters === ['format' => 'hash']) {
                        return ['cpanelresult' => ['result' => ['status' => 1, 'data' => ['addon_domains' => [['documentroot' => $this->docroot]]]]]];
                    }
                    throw new RuntimeException('Unexpected LiveAPI call.');
                }
            };
            $apiResult = ApplicationDiscovery::fromLiveApi($fakeApi, $username);
            $assert($apiResult['available'] && in_array('WordPress', $apiResult['applications'], true), 'Use only the authenticated LiveAPI home and domain roots.');

            $failedApi = new class {
                public function uapi(string $module, string $function, array $parameters): array
                {
                    return ['cpanelresult' => ['result' => ['status' => 0, 'data' => []]]];
                }
            };
            $assert(!ApplicationDiscovery::fromLiveApi($failedApi, $username)['available'], 'Fail closed when cPanel domain metadata is unavailable.');
        }
    }
} finally {
    $removeTree($base);
}

fwrite(STDOUT, "cPanel application discovery checks passed: {$checks}\n");
