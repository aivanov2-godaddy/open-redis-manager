# Live cPanel EA Podman lifecycle smoke — 2026-11-20

## Test identity

- ORM source candidate: `9a8927f` from PR #131.
- SHA-256 verified against the local checkout before execution: `PodmanLifecycleManager.php` `80c0e577a7557e418f24db93e8bd1c260c107e5d5895d1657a823ef88c5f81f1`; `PodmanCacheDiscovery.php` `43bf8add7bb8e45ad564867619a03dbb6d113c4ee2fd2bc88652e12bde44d126`.
- Host purpose: owner-designated disposable cPanel test system.
- Operating system: AlmaLinux 10.3.
- cPanel & WHM: 11.138.0.27, RELEASE tier.
- Runtime exercised: EasyApache PHP 8.5 CLI running as the test cPanel account through `machinectl`.
- CloudLinux: not present. CageFS, PHP Selector, the cPanel internal PHP runtime, and the web PHP handler were not assessed in this run.
- EA packages: the globally installed `ea-valkey72` package supplied a Valkey 7.2.4 service for the temporary account test.
- Host, account, domain, and container identifiers are intentionally omitted.

## Scenario results

| Scenario | Result | Sanitized observation |
|---|---|---|
| Existing Redis baseline | PASS | The account-owned Redis 6.2.24 service was reachable before and after the Valkey test. No key names or values were read or written. |
| Stopped-container discovery | PASS | The newly installed Valkey container was stopped before the manager test; discovery reported its socket as missing. |
| Start | PASS | The account-context manager started the Valkey container; discovery reported the socket reachable and PING succeeded. |
| Stop | PASS | The manager stopped Valkey; discovery returned to the missing-socket state. |
| Start after stop | PASS | The manager started Valkey again; bounded PING succeeded. |
| Restart | PASS | The manager restarted Valkey; bounded PING succeeded afterward. |
| Cleanup | PASS | cPanel's `ea-podman uninstall --verify` removed the temporary container. The account-level `ea-podman clean --run --days=0` removed its now-unreferenced uninstall backup directory. Temporary validation source files were removed. The global EA Valkey package remains installed for further owner-authorized testing. |
| cPanel web form/session integration | NOT RUN | The PHP lifecycle manager ran directly as the account through `machinectl`; no authenticated browser POST was submitted. |

## Result and limitations

- The fixed account-level start/stop/restart path works on this one cPanel host and account using the exact candidate source recorded above.
- The smoke does not validate browser session routing, UI rendering, cross-account denial on multiple accounts, direct Redis/Valkey service management, backups, migration, AUTH, recovery, uninstall of ORM, or the supported OS/PHP matrix.
- ORM support decision: `NOT ESTABLISHED`.

## Sanitization review

This record contains no hostname, IP address, domain, account name, container identifier, socket path, credential, session URL, key/value, or raw command output.
