# Independent cPanel identity query-spoof smoke — 2026-11-20

## Scenario

The updated read-only live smoke harness authenticated through WHM's temporary cPanel SSO flow on the owner-designated disposable test host. It checked the installed ORM cPanel entry point with two distinct account-shaped query-spoof targets. For each target, it sent separate GET requests for `user`, `username`, and `account`, then required the rendered LiveAPI identity to remain exactly equal to the SSO-selected account.

## Result

| Scenario | Result | Sanitized observation |
|---|---|---|
| SSO-selected identity | PASS | The rendered identity matched the SSO-selected account. |
| Independent query parameters | PASS | Each of `user`, `username`, and `account` was tested in its own request. |
| Multiple spoof targets | PASS | Both targets left the SSO-selected identity unchanged. |
| Secret and page-content handling | PASS | The harness printed only its pass result and did not save the session URL, credentials, account names, or response content. |
| Resource-level cross-account authorization | NOT RUN | This check verifies identity binding only; it does not request another real account's resources. |

## Scope

This is a read-only authenticated HTTP smoke against the currently installed entry point. It is not a byte-identical package deployment, a two-real-account resource isolation test, or a browser visual review. No Redis/Valkey data, account state, service state, or package files were changed.

## Sanitization review

This record omits the hostname, IP address, domains, account names, credentials, API tokens, session URLs, private keys, and raw output.
