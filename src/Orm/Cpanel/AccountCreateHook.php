<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** Parses the documented cPanel Accounts::Create post-hook envelope. */
final class AccountCreateHook
{
    private const MAX_EVENT_BYTES = 16384;

    /**
     * @return array{username:string}|null
     */
    public static function request(mixed $input): ?array
    {
        if (!is_string($input) || $input === '' || strlen($input) > self::MAX_EVENT_BYTES) {
            return null;
        }
        try {
            $event = json_decode($input, true, 8, JSON_THROW_ON_ERROR);
        } catch (\Throwable) {
            return null;
        }
        if (!is_array($event) || ($event['context'] ?? null) !== 'Whostmgr::Accounts::Create'
            || !is_array($event['data'] ?? null)) {
            return null;
        }
        $candidates = [];
        foreach (['username', 'user'] as $field) {
            $value = $event['data'][$field] ?? null;
            if ($value !== null) {
                if (!is_string($value) || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $value) !== 1) {
                    return null;
                }
                $candidates[] = $value;
            }
        }
        if ($candidates === [] || count(array_unique($candidates, SORT_STRING)) !== 1) {
            return null;
        }
        return ['username' => $candidates[0]];
    }

    /** @param array{username:string} $request */
    public static function brokerFrame(array $request): ?string
    {
        if (!is_string($request['username'] ?? null)
            || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $request['username']) !== 1) {
            return null;
        }
        try {
            return json_encode([
                'operation' => 'fleet.auto_provision',
                'username' => $request['username'],
                'version' => 1,
            ], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
        } catch (\Throwable) {
            return null;
        }
    }
}
