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
        if (!is_callable([$liveApi, 'uapi'])) {
            return null;
        }

        try {
            $response = $liveApi->uapi('Variables', 'get_user_information', ['name' => 'user']);
        } catch (\Throwable) {
            return null;
        }

        if (!is_array($response)) {
            return null;
        }
        $result = $response['cpanelresult']['result'] ?? null;
        if (!is_array($result) || !in_array($result['status'] ?? null, [1, '1'], true)) {
            return null;
        }
        $data = $result['data'] ?? null;
        $username = is_array($data) ? ($data['user'] ?? null) : null;
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
