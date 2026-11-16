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
