<?php
declare(strict_types=1);

namespace Orm\Security;

/** Require a cPanel/WHM POST through a cpsess URL; cpsrvd validates the token itself. */
final class SessionRequestGuard
{
    /** @param array<string, mixed> $server */
    public static function rejectsMutation(array $server): bool
    {
        return ($server['REQUEST_METHOD'] ?? null) === 'POST'
            && !self::allowsMutation($server);
    }

    /** @param array<string, mixed> $server */
    public static function allowsMutation(array $server): bool
    {
        if (($server['REQUEST_METHOD'] ?? null) !== 'POST') {
            return false;
        }
        $uri = $server['REQUEST_URI'] ?? null;
        return is_string($uri) && strlen($uri) <= 8192
            && preg_match('~\\A/cpsess[0-9]{10}(?:/|\\?|\\z)~', $uri) === 1;
    }
}
