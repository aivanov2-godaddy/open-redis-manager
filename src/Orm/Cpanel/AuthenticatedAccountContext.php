<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** A validated account identity obtained from the current cPanel LiveAPI session. */
final class AuthenticatedAccountContext
{
    private function __construct(private readonly string $username)
    {
    }

    /**
     * Read the authenticated account from cPanel itself. Never accept this value
     * from a query parameter, form field, cookie, or ordinary web-server header.
     */
    public static function fromLiveApi(object $liveApi): ?self
    {
        if (!is_callable([$liveApi, 'cpanelprint'])) {
            return null;
        }

        try {
            // cPanel documents this LiveAPI value for the authenticated account.
            // cpanelprint is deprecated upstream, but remains the documented PHP
            // interface while the replacement UAPI response is version-checked.
            $username = $liveApi->cpanelprint('$user');
        } catch (\Throwable) {
            return null;
        }

        if (!is_string($username) || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1) {
            return null;
        }

        return new self($username);
    }

    public function username(): string
    {
        return $this->username;
    }
}
