<?php
declare(strict_types=1);

$whmPage = file_get_contents(dirname(__DIR__) . '/packaging/whm/cgi/addon_open_redis_manager.php');
$cpanelPage = file_get_contents(dirname(__DIR__) . '/packaging/cpanel/files/orm/index.live.php');
$packageMap = file_get_contents(dirname(__DIR__) . '/packaging/lib.sh');
$releasePreview = file_get_contents(dirname(__DIR__) . '/src/Orm/Update/ReleasePreview.php');
$releaseApplyJob = file_get_contents(dirname(__DIR__) . '/src/Orm/Update/ReleaseApplyJob.php');
$assertions = [
    is_string($whmPage) && str_contains($whmPage, 'new \\Orm\\Backend\\ProviderPolicyStore()'),
    is_string($whmPage) && str_contains($whmPage, '$rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation($_SERVER)')
        && str_contains($whmPage, "'provider.policy.update'"),
    is_string($whmPage) && str_contains($whmPage, 'if (!$rootAuthorized)')
        && str_contains($whmPage, 'Provider policy and new instance defaults'),
    is_string($whmPage) && str_contains($whmPage, 'instance_default_memory_mib')
        && str_contains($whmPage, 'instance_default_eviction')
        && str_contains($whmPage, 'instance_default_databases')
        && str_contains($whmPage, 'instance_default_history_days')
        && str_contains($whmPage, 'does not rewrite an existing instance'),
    is_string($whmPage) && str_contains($whmPage, 'default_max_clients')
        && str_contains($whmPage, 'default_max_databases') && str_contains($whmPage, 'package_max_clients')
        && str_contains($whmPage, 'package_max_databases') && str_contains($whmPage, 'Client ceiling')
        && str_contains($whmPage, 'Database ceiling'),
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
        && str_contains($cpanelPage, "'client_limit_exceeded' => 'the requested client limit exceeds a package ceiling'")
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
    is_string($whmPage) && str_contains($whmPage, "'update.preview'") && str_contains($whmPage, 'Verify staged release')
        && str_contains($whmPage, 'runs asynchronously and uses the transactional updater')
        && str_contains($whmPage, 'aria-labelledby="orm-update-preview-title"'),
    is_string($whmPage) && str_contains($whmPage, "'update.apply'") && str_contains($whmPage, "'update.status'")
        && str_contains($whmPage, 'name="confirm_update"') && str_contains($whmPage, 'Queue signed update')
        && str_contains($whmPage, 'Check update status'),
    is_string($releaseApplyJob) && str_contains($releaseApplyJob, "'--no-block'")
        && str_contains($releaseApplyJob, "'--collect'") && str_contains($releaseApplyJob, 'submissionMatchesPreview')
        && str_contains($releaseApplyJob, "'recovery_required'") && str_contains($releaseApplyJob, 'proc_open($argv'),
    is_string($packageMap) && str_contains($packageMap, 'release_apply "$ORM_PACKAGE_ROOT/apply-release.sh"')
        && str_contains($packageMap, 'release_worker "$ORM_REPO_ROOT/bin/orm-update-worker.pl"')
        && str_contains($packageMap, 'release_apply_ui "$ORM_REPO_ROOT/src/Orm/Update/ReleaseApplyJob.php"'),
    is_string($releasePreview) && str_contains($releasePreview, "private const STAGED_ROOT = '/var/cpanel/orm/updates/staged'")
        && str_contains($releasePreview, "private const TRUSTED_KEY_ROOT = '/etc/orm/release-keys'")
        && str_contains($releasePreview, "'/usr/bin/timeout', '--signal=KILL', '30s', '/usr/bin/bash'")
        && str_contains($releasePreview, 'proc_open($argv')
        && str_contains($releasePreview, "'PATH' => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'"),
    is_string($packageMap) && str_contains($packageMap, 'release_preview "$ORM_PACKAGE_ROOT/preview-release.sh"')
        && str_contains($packageMap, 'release_version "$ORM_REPO_ROOT/VERSION"')
        && str_contains($packageMap, 'release_preview_ui "$ORM_REPO_ROOT/src/Orm/Update/ReleasePreview.php"'),
];
foreach ($assertions as $index => $passed) {
    if (!$passed) {
        fwrite(STDERR, "FAIL: provider policy UI assertion " . ($index + 1) . "\n");
        exit(1);
    }
}
fwrite(STDOUT, 'Provider policy UI checks passed: ' . count($assertions) . "\n");
