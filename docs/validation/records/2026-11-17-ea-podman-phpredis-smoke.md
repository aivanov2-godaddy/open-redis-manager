# cPanel EA Podman PhpRedis socket smoke — 2026-11-17

## Evidence source

The repository owner supplied the sanitized command result for this test-account check. It was not rerun by the repository validation harness during this turn.

## Scenario

An account-context EasyApache PHP 8.5 CLI process instantiated PhpRedis, connected to the account's cPanel EA Podman Redis Unix socket using port `0`, and called `PING`. The output was `1`.

| Scenario | Result | Evidence |
|---|---|---|
| PHP 8.5 CLI has PhpRedis available | PASS | The supplied command constructed `Redis` and completed without an extension or class error. |
| Account PHP process can connect to its EA Podman socket | PASS | `connect` returned and `PING` returned `1`. |
| Redis lifecycle, key access, or data preservation | NOT RUN | The command only established a connection and issued `PING`. |
| ORM discovery or UI behavior on the installed host | NOT RUN | This direct PHP CLI probe did not exercise the ORM page or broker. |
| Valkey, other PHP handlers, CageFS/PHP Selector, or cross-account isolation | NOT RUN | Not covered by the supplied command. |

## Limits

This is evidence for one test account, one EasyApache PHP CLI runtime, and one cPanel EA Podman Redis socket. It does not establish ORM release compatibility, production support, container lifecycle behavior, or the broader cPanel/WHM validation matrix. The raw socket path, host, account name, and credentials are intentionally omitted.
