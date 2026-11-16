<?php
declare(strict_types=1);

namespace Orm\Cpanel;

use Closure;
use Throwable;

/** Cross-checks the LiveAPI account against identity derived by the local broker. */
final class BrokerIdentityVerifier
{
    private const SOCKET_PATH = 'unix:///run/orm/broker.sock';
    private const MAX_RESPONSE_BYTES = 4096;
    private ?Closure $exchange;

    /** @param null|callable(string): ?string $exchange Test seam; production uses the fixed Unix socket. */
    public function __construct(?callable $exchange = null)
    {
        $this->exchange = $exchange === null ? null : Closure::fromCallable($exchange);
    }

    public function verifies(string $authenticatedUsername): bool
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $authenticatedUsername) !== 1) {
            return false;
        }

        $request = "{\"operation\":\"identity\",\"version\":1}\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request)
            : ($this->exchange)($request);

        if (!is_string($response) || $response === '' || strlen($response) > self::MAX_RESPONSE_BYTES
            || !str_ends_with($response, "\n") || substr_count($response, "\n") !== 1) {
            return false;
        }

        try {
            $decoded = json_decode(substr($response, 0, -1), true, 4, JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            return false;
        }

        if (!is_array($decoded)) {
            return false;
        }
        $keys = array_keys($decoded);
        sort($keys);
        if ($keys !== ['success', 'username', 'version']) {
            return false;
        }

        $brokerUsername = $decoded['username'];
        return $decoded['version'] === 1
            && $decoded['success'] === true
            && is_string($brokerUsername)
            && preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $brokerUsername) === 1
            && hash_equals($authenticatedUsername, $brokerUsername);
    }

    private function exchangeWithLocalBroker(string $request): ?string
    {
        $errno = 0;
        $error = '';
        $stream = @stream_socket_client(
            self::SOCKET_PATH,
            $errno,
            $error,
            1.0,
            STREAM_CLIENT_CONNECT
        );
        if (!is_resource($stream)) {
            return null;
        }

        stream_set_timeout($stream, 1);
        $written = 0;
        while ($written < strlen($request)) {
            $count = @fwrite($stream, substr($request, $written));
            if (!is_int($count) || $count <= 0) {
                fclose($stream);
                return null;
            }
            $written += $count;
        }

        $response = @stream_get_contents($stream, self::MAX_RESPONSE_BYTES + 1);
        $metadata = stream_get_meta_data($stream);
        fclose($stream);
        if (($metadata['timed_out'] ?? false) === true) {
            return null;
        }

        return is_string($response) ? $response : null;
    }
}
