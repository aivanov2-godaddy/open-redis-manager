#!/usr/local/cpanel/3rdparty/bin/php -q
<?php
declare(strict_types=1);

require_once '/usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/AccountCreateHook.php';

const ORM_HOOK_MAX_EVENT_BYTES = 16384;
const ORM_HOOK_MAX_FRAME_BYTES = 4096;

/** Consume the complete event stream while retaining only the bounded prefix. */
function ormReadHookEvent(): ?string
{
    $retained = '';
    $overflow = false;
    while (!feof(STDIN)) {
        $chunk = fread(STDIN, 4096);
        if (!is_string($chunk) || $chunk === '') {
            if (!feof(STDIN)) {
                return null;
            }
            break;
        }
        $remaining = ORM_HOOK_MAX_EVENT_BYTES + 1 - strlen($retained);
        if ($remaining > 0) {
            $retained .= substr($chunk, 0, $remaining);
        }
        if (strlen($chunk) > max(0, $remaining)) {
            $overflow = true;
        }
    }
    return $overflow || strlen($retained) > ORM_HOOK_MAX_EVENT_BYTES ? null : $retained;
}

function ormSendAutoProvision(string $frame): bool
{
    if (strlen($frame) > ORM_HOOK_MAX_FRAME_BYTES || !str_ends_with($frame, "\n")) {
        return false;
    }
    $socket = @stream_socket_client('unix:///run/orm/broker.sock', $errorCode, $errorMessage, 1.0, STREAM_CLIENT_CONNECT);
    if (!is_resource($socket)) {
        return false;
    }
    stream_set_timeout($socket, 2);
    $offset = 0;
    while ($offset < strlen($frame)) {
        $written = @fwrite($socket, substr($frame, $offset));
        if (!is_int($written) || $written < 1) {
            fclose($socket);
            return false;
        }
        $offset += $written;
    }
    @fflush($socket);
    $response = '';
    while (!feof($socket) && strlen($response) <= ORM_HOOK_MAX_FRAME_BYTES) {
        $chunk = @fread($socket, 1024);
        if (!is_string($chunk) || $chunk === '') {
            break;
        }
        $response .= $chunk;
        if (str_contains($response, "\n")) {
            break;
        }
    }
    fclose($socket);
    if (strlen($response) > ORM_HOOK_MAX_FRAME_BYTES || !str_ends_with($response, "\n")) {
        return false;
    }
    try {
        $decoded = json_decode($response, true, 8, JSON_THROW_ON_ERROR);
    } catch (Throwable) {
        return false;
    }
    return is_array($decoded) && is_bool($decoded['success'] ?? null)
        && in_array($decoded['outcome'] ?? null, ['disabled', 'already_present', 'provisioned', 'failed'], true);
}

// Account creation must never fail because optional cache provisioning did.
try {
    $event = ormReadHookEvent();
    $request = $event === null ? null : \Orm\Cpanel\AccountCreateHook::request($event);
    $frame = $request === null ? null : \Orm\Cpanel\AccountCreateHook::brokerFrame($request);
    if ($frame !== null) {
        ormSendAutoProvision($frame);
    }
} catch (Throwable) {
    // The broker owns the auditable result. A post-create hook is best-effort.
}
exit(0);
