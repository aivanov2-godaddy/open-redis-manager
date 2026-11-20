# cPanel account identity and query-spoof smoke — 2026-11-20

## Test identity

- Smoke harness source commit: `7297a93` (`main`, PR #133).
- Host purpose: owner-designated disposable cPanel test system.
- Operating system: AlmaLinux 10.3.
- cPanel & WHM: 138.0 RELEASE, build 27.
- The harness was downloaded from the exact commit and its SHA-256 was compared with the repository copy before execution.
- The harness chose the single cPanel account on the host, created a temporary WHM SSO session, and kept its URL and account identity in memory.

## Scenario results

| Scenario | Result | Sanitized observation / evidence |
|---|---|---|
| Exact account identity | PASS | The authenticated page's displayed LiveAPI account matched the account selected for the SSO session. |
| Query-parameter spoof resistance | PASS | A second read-only GET set `user`, `username`, and `account` to `root`; the page continued to display the SSO-selected account. |
| Secret and page-content handling | PASS | The harness printed only its pass result; it did not print or save account names, page content, the session URL, or credentials. |
| Cross-account isolation with two accounts | NOT RUN | The host had one test account; this probe does not exercise access to a second account's initialized instance. |
| WHM ACL and state-changing actions | NOT RUN | The check performs only GET requests against the cPanel page. |

## Installed-source scope

- The installed package on the host was older than the repository checkout at the time of this run. A prior file comparison found the installed cPanel entry point did not match the current repository file; the account-context and broker-identity helper files did match.
- Therefore, this result verifies the installed page's identity presentation against the exact current smoke harness, not a byte-identical current package deployment, a full install/upgrade, or the broader host matrix.
- No Redis/Valkey command, service action, account change, or package mutation was performed.

## Result

- Overall result: one-account SSO identity and query-parameter spoof smoke passed on one disposable cPanel host.
- ORM support decision: `NOT ESTABLISHED`.
- Cross-account isolation, WHM ACL behavior, and source-matched package validation remain release gates.

## Sanitization review

This record omits the hostname, IP address, domains, account name, credentials, API tokens, session URLs, private keys, and raw output.
