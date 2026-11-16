<?php
declare(strict_types=1);

$whmPage = file_get_contents(dirname(__DIR__) . '/packaging/whm/cgi/addon_open_redis_manager.php');
$cpanelPage = file_get_contents(dirname(__DIR__) . '/packaging/cpanel/files/orm/index.live.php');
$packageMap = file_get_contents(dirname(__DIR__) . '/packaging/lib.sh');
$assertions = [
    is_string($whmPage) && str_contains($whmPage, 'new \\Orm\\Backend\\ProviderPolicyStore()'),
    is_string($whmPage) && str_contains($whmPage, '$rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation($_SERVER)')
        && str_contains($whmPage, "'provider.policy.update'"),
    is_string($whmPage) && str_contains($whmPage, 'if (!$rootAuthorized)')
        && str_contains($whmPage, 'Package resource policy'),
    is_string($whmPage) && str_contains($whmPage, "error_log('ORM provider policy changed through root WHM"),
    is_string($cpanelPage) && str_contains($cpanelPage, "'provider_policy_denied'")
        && str_contains($cpanelPage, "'provider_policy_unavailable'"),
    is_string($cpanelPage) && str_contains($cpanelPage, "'package_disabled' => 'this package is marked unavailable'")
        && str_contains($cpanelPage, "'memory_limit_exceeded' => 'the selected profile exceeds its package memory ceiling'"),
    is_string($packageMap) && str_contains($packageMap, 'ProviderPolicyStore.php')
        && str_contains($packageMap, 'ProviderPolicy.pm'),
];
foreach ($assertions as $index => $passed) {
    if (!$passed) {
        fwrite(STDERR, "FAIL: provider policy UI assertion " . ($index + 1) . "\n");
        exit(1);
    }
}
fwrite(STDOUT, 'Provider policy UI checks passed: ' . count($assertions) . "\n");
