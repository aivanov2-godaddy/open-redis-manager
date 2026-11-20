# Issue: Add optional signed provider automation events

Reference: the public cPanel Redis Manager documentation describes provider hook events for backend changes, denied access, quota limits and billing automation. This is a separately designed ORM capability, not a promise to reproduce vendor internals or commercial licensing.

## Scope

Provide an opt-in adapter that lets hosting providers receive a small, fixed set of ORM lifecycle and policy events. The service-management core must work fully with the adapter disabled. WHMCS-specific licensing and billing remain outside the core; providers may build their own integration on the documented event contract.

## Acceptance criteria

- Define and document a versioned, fixed event catalog, including backend selection/change, policy denial, quota reached, and supported instance lifecycle events.
- Disabled by default. Root WHM can configure, validate, rotate and disable an HTTPS destination and signing key; never expose key material to cPanel accounts or include it in diagnostics, audit exports or event bodies.
- Sign canonical event envelopes and include event IDs, timestamps and a schema version. Receivers can reject invalid signatures, stale deliveries and replayed IDs.
- Use bounded, persistent delivery state with capped retries, backoff, expiration, queue limits and an operator-visible delivery health view. Failure to deliver must never block or roll back a Redis/Valkey operation.
- Minimize payloads: no credentials, Redis keys/values, raw commands, connection strings or free-form user input. Document any account identifiers and allow providers to disable or pseudonymize them.
- Restrict destinations to HTTPS; reject redirects, unsafe address resolution and requests to local/private/link-local destinations. Protect against DNS rebinding and SSRF at connection time.
- Record configuration and delivery outcomes in the existing root-only audit journal without recording secrets or sensitive response bodies.
- Add tests for signature canonicalization, timestamp bounds, duplicate IDs, endpoint validation, queue bounds, retry behavior, redaction and non-blocking service operations; update the security model and integrations guide.
- Include a source-matched disposable-host validation record before claiming production readiness.

## Not in scope

- A built-in WHMCS client, commercial license enforcement, vendor billing APIs, arbitrary shell hooks, user-configurable scripts, event forwarding to non-HTTPS endpoints, or automatic event subscriptions without operator consent.
