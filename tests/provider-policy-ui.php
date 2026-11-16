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
    is_string($whmPage) && str_contains($whmPage, 'WhmAuditEventWriter::providerPolicyChanged($providerAction)')
        && str_contains($whmPage, 'WhmAuditEventWriter::backendSelection($submittedBackend, true)'),
    is_string($whmPage) && str_contains($whmPage, '$rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation($_SERVER)')
        && str_contains($whmPage, "in_array(\$_POST['orm_audit_action'] ?? null, ['search', 'export'], true)")
        && str_contains($whmPage, "'Cache-Control: private, no-store, max-age=0'")
        && str_contains($whmPage, "'X-Content-Type-Options: nosniff'")
        && str_contains($whmPage, 'Download normalized JSON'),
    is_string($whmPage) && str_contains($whmPage, 'name="provider_exposure"')
        && str_contains($whmPage, 'value="warn"') && str_contains($whmPage, 'Reseller quotas'),
    is_string($whmPage) && str_contains($whmPage, "request('provider.resellers')")
        && str_contains($whmPage, 'max_memory_mib') && str_contains($whmPage, 'active_instances'),
    is_string($whmPage) && str_contains($whmPage, 'Provider branding')
        && str_contains($whmPage, 'type="file" accept="image/png"')
        && str_contains($whmPage, 'branding_primary_color') && str_contains($whmPage, 'branding_secondary_color')
        && str_contains($whmPage, 'branding_surface_color') && str_contains($whmPage, 'branding_text_color')
        && str_contains($whmPage, 'branding_preset') && str_contains($whmPage, 'UnderHost-inspired')
        && str_contains($whmPage, 'orm-branding-preview') && str_contains($whmPage, 'is_uploaded_file'),
    is_string($cpanelPage) && str_contains($cpanelPage, "'provider_policy_denied'")
        && str_contains($cpanelPage, "'provider_policy_unavailable'"),
    is_string($cpanelPage) && str_contains($cpanelPage, "'package_disabled' => 'this package is marked unavailable'")
        && str_contains($cpanelPage, "'memory_limit_exceeded' => 'the requested memory exceeds a package ceiling'")
        && str_contains($cpanelPage, "'reseller_memory_quota_exceeded' => 'the reseller memory limit has been reached'"),
    is_string($cpanelPage) && str_contains($cpanelPage, '$developerExposure')
        && str_contains($cpanelPage, '$advancedExposure') && str_contains($cpanelPage, "request('provider.exposure')")
        && str_contains($cpanelPage, ": 'simple';") && !str_contains($cpanelPage, "request('provider.resellers')"),
    is_string($cpanelPage) && str_contains($cpanelPage, "request('provider.branding')")
        && str_contains($cpanelPage, 'data:image/png;base64,') && str_contains($cpanelPage, '$providerBranding[\'support_url\']')
        && str_contains($cpanelPage, 'footer_visible') && str_contains($cpanelPage, '--orm-primary')
        && str_contains($cpanelPage, '--orm-surface') && str_contains($cpanelPage, '--orm-text')
        && str_contains($cpanelPage, 'Open Redis Manager cache cube')
        && str_contains($whmPage, 'Open Redis Manager cache cube')
        && !str_contains($cpanelPage, 'M169 80a66 66 0 1 0 0 96')
        && !str_contains($whmPage, 'M169 80a66 66 0 1 0 0 96')
        && !str_contains($cpanelPage, 'M75 205V53h66c35 0 55 18 55 48')
        && !str_contains($whmPage, 'M75 205V53h66c35 0 55 18 55 48'),
    is_string($whmPage) && str_contains($whmPage, "'fleet.migrate'")
        && str_contains($whmPage, 'migrateFleetAccount($username, $targetBackend, $writesQuiesced)')
        && str_contains($whmPage, 'name="writes_quiesced"') && str_contains($whmPage, 'SessionRequestGuard::allowsMutation($_SERVER)'),
    is_string($whmPage) && str_contains($whmPage, '$rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation($_SERVER)')
        && str_contains($whmPage, "'fleet.diagnostics'")
        && str_contains($whmPage, 'diagnoseFleetAccount($username)')
        && str_contains($whmPage, 'Read-only diagnostics for')
        && str_contains($whmPage, 'Keys in database 0')
        && str_contains($whmPage, 'Only fixed, read-only Redis/Valkey probes are used')
        && !str_contains($whmPage, "\$_POST['command']"),
    is_string($whmPage) && str_contains($whmPage, "'fleet.recovery.scan'")
        && str_contains($whmPage, "'fleet.recovery.repair'")
        && str_contains($whmPage, 'scanFleetRecovery($username)')
        && str_contains($whmPage, 'repairFleetAccount($username, $repair)')
        && str_contains($whmPage, 'Read-only scan') && str_contains($whmPage, 'Start service')
        && str_contains($whmPage, 'verified configured ORM accounts in the full inventory')
        && str_contains($whmPage, 'State counts for this page only')
        && str_contains($whmPage, '<option value="unhealthy">Unverifiable</option>')
        && str_contains($whmPage, "? 'Unverifiable' : ucfirst(\$entry['state'])")
        && str_contains($whmPage, 'manifest, ownership, or service state'),
    is_string($packageMap) && str_contains($packageMap, 'ProviderPolicyStore.php')
        && str_contains($packageMap, 'ProviderPolicy.pm')
        && str_contains($packageMap, 'WhmAuditLog.php') && str_contains($packageMap, 'WhmAuditEventWriter.php'),
];
foreach ($assertions as $index => $passed) {
    if (!$passed) {
        fwrite(STDERR, "FAIL: provider policy UI assertion " . ($index + 1) . "\n");
        exit(1);
    }
}
fwrite(STDOUT, 'Provider policy UI checks passed: ' . count($assertions) . "\n");
