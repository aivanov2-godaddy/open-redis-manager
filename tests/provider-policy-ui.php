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
    is_string($whmPage) && str_contains($whmPage, 'name="provider_exposure"')
        && str_contains($whmPage, 'value="warn"') && str_contains($whmPage, 'Reseller quotas'),
    is_string($whmPage) && str_contains($whmPage, "request('provider.resellers')")
        && str_contains($whmPage, 'max_memory_mib') && str_contains($whmPage, 'active_instances'),
    is_string($cpanelPage) && str_contains($cpanelPage, "'provider_policy_denied'")
        && str_contains($cpanelPage, "'provider_policy_unavailable'"),
    is_string($cpanelPage) && str_contains($cpanelPage, "'package_disabled' => 'this package is marked unavailable'")
        && str_contains($cpanelPage, "'memory_limit_exceeded' => 'the requested memory exceeds a package ceiling'")
        && str_contains($cpanelPage, "'reseller_memory_quota_exceeded' => 'the reseller memory limit has been reached'"),
    is_string($cpanelPage) && str_contains($cpanelPage, '$developerExposure')
        && str_contains($cpanelPage, '$advancedExposure') && str_contains($cpanelPage, "request('provider.exposure')")
        && str_contains($cpanelPage, ": 'simple';") && !str_contains($cpanelPage, "request('provider.resellers')"),
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
