<?php
declare(strict_types=1);

namespace Orm\Security;

/** Emits only the fixed, metadata-only WHM audit event schemas. */
final class WhmAuditEventWriter
{
    private const PROVIDER_ACTIONS = [
        'default' => 'provider.default',
        'save-package' => 'provider.package.save',
        'remove-package' => 'provider.package.remove',
        'save-reseller' => 'provider.reseller.save',
        'remove-reseller' => 'provider.reseller.remove',
        'save-branding' => 'provider.branding.save',
    ];

    public static function providerPolicyChanged(string $inputAction): bool
    {
        $action = self::PROVIDER_ACTIONS[$inputAction] ?? null;
        return is_string($action) && self::write('provider_policy actor_uid=0 account=global action=' . $action . ' result=success state=updated');
    }

    public static function backendSelection(string $backend, bool $success): bool
    {
        if (!in_array($backend, ['redis', 'valkey', 'unavailable'], true)) {
            return false;
        }
        return self::write('backend_policy actor_uid=0 account=global action=backend.select result='
            . ($success ? 'success' : 'failure') . ' state=' . $backend);
    }

    public static function providerEventsChanged(bool $success, bool $enabled, bool $keyRotated): bool
    {
        $state = $success ? ($enabled ? 'enabled' : 'disabled') . ($keyRotated ? ',key_rotated' : '') : 'rejected';
        return self::write('provider_events actor_uid=0 account=global action=provider.events.configure result='
            . ($success ? 'success' : 'failure') . ' state=' . $state);
    }

    public static function securityReportGenerated(): bool
    {
        return self::write('security_report actor_uid=0 account=global action=security.report result=success state=generated');
    }

    public static function securityReportPolicyChanged(bool $success): bool
    {
        return self::write('security_report_policy actor_uid=0 account=global action=security.thresholds.update result='
            . ($success ? 'success' : 'failure') . ' state=' . ($success ? 'updated' : 'rejected'));
    }

    private static function write(string $message): bool
    {
        if (!function_exists('openlog') || !function_exists('syslog') || !function_exists('closelog')
            || !defined('LOG_PID') || !defined('LOG_AUTHPRIV') || !defined('LOG_NOTICE')) {
            return false;
        }
        $opened = @openlog('orm-whm', LOG_PID, LOG_AUTHPRIV);
        if ($opened === false) {
            return false;
        }
        try {
            return @syslog(LOG_NOTICE, $message);
        } finally {
            @closelog();
        }
    }
}
