<?php
declare(strict_types=1);

namespace Orm\Security;

/** Fail-closed check for the root-level WHM ACL used by ORM's AppConfig entry. */
final class WhmAcl
{
    private const RESELLERS_FILE = '/var/cpanel/resellers';
    private const MAX_RESELLERS_FILE_BYTES = 4_194_304;

    public static function allowsAdministrativeAccess(?string $authenticatedUser): bool
    {
        if ($authenticatedUser === null || preg_match('/\A[a-zA-Z0-9_.-]{1,64}\z/', $authenticatedUser) !== 1) {
            return false;
        }
        if ($authenticatedUser === 'root') {
            return true;
        }
        if (!is_file(self::RESELLERS_FILE) || !is_readable(self::RESELLERS_FILE)) {
            return false;
        }

        $handle = @fopen(self::RESELLERS_FILE, 'rb');
        if (!is_resource($handle)) {
            return false;
        }
        $contents = stream_get_contents($handle, self::MAX_RESELLERS_FILE_BYTES + 1);
        fclose($handle);
        if (!is_string($contents)) {
            return false;
        }

        return self::resellerFileAllowsAdministrativeAccess($authenticatedUser, $contents);
    }

    private static function resellerFileAllowsAdministrativeAccess(string $authenticatedUser, string $contents): bool
    {
        if (strlen($contents) > self::MAX_RESELLERS_FILE_BYTES) {
            return false;
        }

        foreach (preg_split('/\r?\n/', $contents) ?: [] as $line) {
            $separator = strpos($line, ':');
            if ($separator === false) {
                continue;
            }

            $username = substr($line, 0, $separator);
            $permissions = array_map('trim', explode(',', substr($line, $separator + 1)));
            if ($username === $authenticatedUser && in_array('all', $permissions, true)) {
                return true;
            }
        }

        return false;
    }
}
