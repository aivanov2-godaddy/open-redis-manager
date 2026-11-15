<?php
declare(strict_types=1);

namespace Orm\Cpanel;

use Throwable;

/** Sends fixed ORM operations to the local broker and validates their bounded replies. */
final class BrokerClient
{
    private const SOCKET_PATH = 'unix:///run/orm/broker.sock';
    private const MAX_RESPONSE_BYTES = 4096;
    private const OPERATIONS = [
        'instance.status',
        'instance.provision',
        'instance.start',
        'instance.stop',
    ];

    /** @param null|callable(string): ?string $exchange Test seam; production uses the fixed Unix socket. */
    public function __construct(private readonly mixed $exchange = null)
    {
        if ($exchange !== null && !is_callable($exchange)) {
            throw new \InvalidArgumentException('The broker exchange must be callable.');
        }
    }

    /** @return array{success:bool,version:int,state?:string,error?:string}|null */
    public function request(string $operation): ?array
    {
        if (!in_array($operation, self::OPERATIONS, true)) {
            return null;
        }

        $request = json_encode(
            ['operation' => $operation, 'version' => 1],
            JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
        ) . "\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request)
            : ($this->exchange)($request);
        if (!is_string($response) || $response === '' || strlen($response) > self::MAX_RESPONSE_BYTES
            || !str_ends_with($response, "\n") || substr_count($response, "\n") !== 1) {
            return null;
        }

        try {
            $decoded = json_decode(substr($response, 0, -1), true, 4, JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            return null;
        }
        if (!is_array($decoded) || ($decoded['version'] ?? null) !== 1 || !is_bool($decoded['success'] ?? null)) {
            return null;
        }

        if ($decoded['success']) {
            $keys = array_keys($decoded);
            sort($keys);
            if ($keys !== ['state', 'success', 'version']
                || !in_array($decoded['state'], ['not_configured', 'stopped', 'starting', 'running', 'stopping', 'failed'], true)) {
                return null;
            }
            return ['success' => true, 'state' => $decoded['state'], 'version' => 1];
        }

        $keys = array_keys($decoded);
        sort($keys);
        if ($keys !== ['error', 'success', 'version']
            || !in_array($decoded['error'], [
                'invalid_request', 'not_authorized', 'operation_failed', 'instance_unavailable',
                'instance_exists', 'storage_unavailable', 'backend_policy_required', 'backend_unavailable',
                'service_failed', 'not_configured', 'rate_limited',
            ], true)) {
            return null;
        }
        return ['success' => false, 'error' => $decoded['error'], 'version' => 1];
    }

    /** @return array{success:bool,version:int,offset:int,total:int,entries:list<array{username:string,state:string}>}|null */
    public function requestFleetPage(int $offset): ?array
    {
        if ($offset < 0 || $offset > 10000) {
            return null;
        }
        $request = json_encode(
            ['offset' => $offset, 'operation' => 'fleet.list', 'version' => 1],
            JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
        ) . "\n";
        $response = $this->exchange === null
            ? $this->exchangeWithLocalBroker($request)
            : ($this->exchange)($request);
        if (!is_string($response) || $response === '' || strlen($response) > self::MAX_RESPONSE_BYTES
            || !str_ends_with($response, "\n") || substr_count($response, "\n") !== 1) {
            return null;
        }

        try {
            $decoded = json_decode(substr($response, 0, -1), true, 6, JSON_THROW_ON_ERROR);
        } catch (Throwable) {
            return null;
        }
        if (!is_array($decoded) || ($decoded['success'] ?? null) !== true || ($decoded['version'] ?? null) !== 1
            || ($decoded['offset'] ?? null) !== $offset || !is_int($decoded['total'] ?? null)
            || $decoded['total'] < 0 || $decoded['total'] > 10000 || !is_array($decoded['entries'] ?? null)
            || count($decoded['entries']) > 4) {
            return null;
        }
        $keys = array_keys($decoded);
        sort($keys);
        if ($keys !== ['entries', 'offset', 'success', 'total', 'version']) {
            return null;
        }
        $previous = '';
        foreach ($decoded['entries'] as $entry) {
            if (!is_array($entry) || !is_string($entry['username'] ?? null)
                || preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $entry['username']) !== 1
                || $entry['username'] <= $previous || !is_string($entry['state'] ?? null)
                || !in_array($entry['state'], ['stopped', 'starting', 'running', 'stopping', 'failed', 'unhealthy'], true)) {
                return null;
            }
            $entryKeys = array_keys($entry);
            sort($entryKeys);
            if ($entryKeys !== ['state', 'username']) {
                return null;
            }
            $previous = $entry['username'];
        }
        if ($offset + count($decoded['entries']) > $decoded['total']) {
            return null;
        }
        return $decoded;
    }

    private function exchangeWithLocalBroker(string $request): ?string
    {
        $errno = 0;
        $error = '';
        $stream = @stream_socket_client(
            self::SOCKET_PATH,
            $errno,
            $error,
            5.0,
            STREAM_CLIENT_CONNECT
        );
        if (!is_resource($stream)) {
            return null;
        }

        stream_set_timeout($stream, 35);
        $written = 0;
        while ($written < strlen($request)) {
            $count = @fwrite($stream, substr($request, $written));
            if (!is_int($count) || $count <= 0) {
                fclose($stream);
                return null;
            }
            $written += $count;
        }
        if (!@stream_socket_shutdown($stream, STREAM_SHUT_WR)) {
            fclose($stream);
            return null;
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
