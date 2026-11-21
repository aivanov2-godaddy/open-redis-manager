# Provider event delivery

ORM can send an optional signed event stream to a provider-owned HTTPS receiver. Delivery is disabled by default. Root WHM controls the destination and key lifecycle; account users cannot configure it. Events are queued locally and sent by a separate root worker, so remote outages do not block Redis or Valkey operations.

## Event types and data

Schema version 1 supports:

| Event | Metadata |
| --- | --- |
| `backend.selected` | `backend`: `redis` or `valkey` |
| `policy.denied` | `operation`: fixed operation name; `reason_code`: fixed reason |
| `quota.reached` | `quota_kind`: `instances` or `memory_mib` |
| `instance.provisioned`, `instance.started`, `instance.stopped`, `instance.restarted` | `backend`: `redis` or `valkey` |
| `instance.failed` | `backend`, fixed `operation`, and fixed `reason_code` |

Envelopes contain a random event ID, UTC occurrence time, event type, schema version, and only the listed metadata. They do not contain account names or IDs, Redis keys or values, credentials, command text, URLs, filesystem paths, raw errors, or response bodies. `policy.denied` is emitted for enforced policy denials; reseller quota events are emitted for enforced reseller quota limits. Lifecycle events are emitted after successful operations, with a fixed failure event for a reported service failure.

## Configure in WHM

1. Open **Open Redis Manager** in root WHM and go to **Provider event delivery**.
2. Enter an HTTPS endpoint on port 443 with a hostname and path. IP literals, credentials, query strings, fragments, nonstandard ports, and destinations resolving to private or special-use addresses are rejected.
3. Save the endpoint while delivery is disabled if you need to coordinate receiver setup first.
4. Enable delivery when the receiver is ready. ORM creates and stores a signing key in a root-owned mode-0600 configuration file. The UI reports only whether a key is configured; it cannot show or export the secret.
5. Provision the receiver's copy of the signing key through your approved secret-management channel. If the key is lost or exposed, select **Rotate signing key**, save, and replace the receiver's key before expecting events to verify. Rotation replaces the previous key and cannot be undone from the UI.

Saving configuration does not send a test event or disclose the key. The WHM audit record contains only the fixed action, result, enabled state, and whether a rotation occurred.

## Receiver verification

The worker sends a `POST` request with canonical UTF-8 JSON and these headers:

- `X-ORM-Schema-Version: 1`
- `X-ORM-Event-Id: <32 lowercase hexadecimal characters>`
- `X-ORM-Event-Timestamp: <UTC timestamp>`
- `X-ORM-Signature: <64 lowercase hexadecimal characters>`

The signature is HMAC-SHA-256 over the exact request-body bytes. The receiver must use the exact shared secret bytes, reject malformed or unknown schema fields, enforce a short timestamp window, compare signatures in constant time, and atomically deduplicate event IDs. ORM retries delivery, so an event can arrive more than once. Return any `2xx` status only after the receiver has durably accepted the event. Non-2xx responses are not considered delivered.

## Queue, retries, and status

The root-owned outbox is capped at 256 active events, 1 MiB total, and 16 KiB per event. Events expire after 24 hours. The worker retries temporary connection failures, `408`, `425`, `429`, and `5xx` responses with capped exponential backoff, at most eight attempts. Redirects and permanent `4xx` responses are rejected. Terminal status is retained for operator inspection for up to 24 hours.

The WHM page shows counts and bounded status fields such as age, attempt count, next attempt, state, and normalized outcome. It does not show event IDs, signatures, payloads, endpoint response bodies, or signing material. Delivery outcomes are written as normalized `orm-provider-events` system journal records; host journal retention determines their availability.

Disable delivery in WHM to stop new delivery attempts. Already queued events remain in the local outbox until their retention window expires; they are not sent while delivery is disabled. Uninstall stops and removes the timer and worker, while preserving provider configuration and outbox state for a later reinstall.

## Network and release limits

The privileged broker has `PrivateNetwork=true` and only appends events locally. The isolated worker resolves A and AAAA records before every delivery, rejects any unsafe answer, pins the selected address, and validates TLS against the original hostname. It does not use proxy settings or follow redirects. Requests and response headers are bounded.

The implementation has focused unit coverage, but it still needs source-matched disposable cPanel validation of installation rollback, service/timer behavior, queue permissions, real TLS verification, delivery retries, and WHM rendering before production-readiness claims. See [the design and verification matrix](../design/provider-event-delivery.md).
