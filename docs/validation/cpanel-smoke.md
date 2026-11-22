# Live cPanel smoke test

`tests/cpanel-live-smoke.py` checks the installed cPanel entry point on a disposable cPanel & WHM host. It uses WHM's temporary single-sign-on session, requires the page's displayed LiveAPI account to exactly match the selected SSO account, and repeats read-only requests with each identity query parameter (`user`, `username`, and `account`) set independently. By default, the spoof target is `root`; the authenticated identity must remain bound to the SSO account. It performs no Redis/Valkey operation.

Run as root on a test host with exactly one cPanel account:

```sh
python3 tests/cpanel-live-smoke.py
```

On a multi-account test host, pass an explicit cPanel username:

```sh
python3 tests/cpanel-live-smoke.py --user example
```

To check one or more known, distinct cPanel accounts as query-spoof targets, repeat `--spoof-account`:

```sh
python3 tests/cpanel-live-smoke.py --user example --spoof-account another --spoof-account third
```

Each target is tested separately in each of the three identity parameters. Targets must be valid cPanel usernames and must differ from the authenticated account. This tests that query values cannot switch the authenticated identity; it does not by itself establish authorization or denial for another account's resources.

To also require that the authenticated page finds a cPanel-managed Redis or Valkey socket and reports its read-only health probe as reachable, add `--require-podman-cache`. This assertion checks only the sanitized rendered status; it does not print account names, container identifiers, socket paths, or page content.

```sh
python3 tests/cpanel-live-smoke.py --user example --require-podman-cache
```

The check requires an installed ORM cPanel entry point, an active `orm-broker.service`, valid HTTPS for the temporary session URL, and WHM API access to `create_user_session`. It reads the session URL and account name only in memory and prints only a pass/fail result. The query-spoof probe is a read-only GET. The optional Podman assertion exercises the account page's existing read-only socket probe. cPanel expires unused temporary sessions; the smoke test does not save credentials, tokens, hostnames, account names, page content, or session URLs.

For a newly created, unconfigured disposable cPanel account with verified empty Podman inventory, run `python3 tests/cpanel-live-smoke.py --user USER --require-first-run-setup`. This mode GETs the backend-choice page and both fixed `orm_setup=native` and `orm_setup=podman` views. It prints only pass/fail status, does not retain response bodies or account details, and does not submit a mutation or run the displayed installation command.

## Authenticated EA Podman lifecycle form

The opt-in lifecycle smoke exercises the cPanel page's actual SSO POST path for an existing account-owned EA Podman Redis/Valkey container. Run it as root on a disposable host, naming the account that owns the disposable cache:

```sh
python3 tests/cpanel-live-podman-lifecycle-smoke.py --user example --confirm-lifecycle
```

The check reads one container ID and its initial state from that account's authenticated page, runs only the fixed start/stop/restart actions, verifies the resulting page state after each request, and returns the container to its initial running/stopped state. It refuses ambiguous, unknown, or unhealthy selections. If the account has both Redis and Valkey, select one explicitly with `--backend redis` or `--backend valkey`; without a selector, a multi-container page is rejected. `--confirm-lifecycle` is required because the test stops the cache briefly. Output omits the account name, container ID, socket path, session URL, cookies, and page content. This check validates the cPanel HTTP/session path, not ORM-managed direct-service lifecycle or cross-account authorization.

For example, to target an account-owned EA Podman Valkey container:

```sh
python3 tests/cpanel-live-podman-lifecycle-smoke.py --user example --backend valkey --confirm-lifecycle
```

The source-matched Valkey page lifecycle passed on the owner-designated test system; see the [sanitized live record](records/2026-11-21-cpanel-ea-valkey-web-lifecycle.md).

## Live two-account Podman web authorization

`tests/cpanel-live-podman-web-isolation-smoke.py` checks that one account cannot stop another account's actual EA Podman Redis/Valkey container through the cPanel form. Each disposable account must own exactly one reachable container. The root-run harness reads each account's EA Podman inventory as that account, validates the socket owner and path, and confirms owner-context Redis PINGs. It then creates one authenticated SSO session at a time and submits the foreign-container `stop` as the first ORM-page request in that session. A pass requires HTTP 200, the source account identity and its own cache form in the response, the Podman section's explicit generic denial, no success message or foreign-container echo, and repeated owner-context PINGs for both containers. Redirects and ambiguous responses fail closed.

```sh
python3 tests/cpanel-live-podman-web-isolation-smoke.py \
  --account-a example-one --account-b example-two \
  --confirm-cross-account-probe
```

The probe does not provision accounts or containers. Use disposable accounts because an authorization regression could briefly stop the foreign container. If a submitted probe leaves either owner-context PING unreachable, recovery invokes only that account owner's fixed `ea-podman start` command for its previously verified container, then checks PING again. A failure before either POST sends no lifecycle request. Output suppresses account names, container IDs, socket paths, session URLs, cookies, command output, and page content. The two-direction Redis probe passed on one source-matched host; see the [sanitized live record](records/2026-11-21-cpanel-podman-web-isolation.md). Repeated same-session GET behavior remains anomalous and is not covered by this first-request authorization check. Offline assertions do not substitute for broader host and Valkey coverage.

## Live two-account broker isolation

`tests/cpanel-live-isolation-smoke.py` probes the installed broker directly as two distinct cPanel Unix users using `runuser`. Supply two accounts and identify which one already owns the disposable ORM-managed instance:

```sh
python3 tests/cpanel-live-isolation-smoke.py \
  --account-a example-one --account-b example-two --fixture-owner a
```

The check requires root, a running broker, safe cPanel account metadata, distinct non-root UIDs, and exactly one configured ORM instance across the two accounts. It compares each peer-credential identity with its own account, checks the instance status and backup-list response shapes, verifies the configured account sees its instance while the other reports `not_configured`, sends username-target fields that must be rejected by the fixed account-operation protocol, and confirms both non-root peers are denied the root-only reseller summary. It reads backup metadata only; it does not read Redis keys or backup contents, and it does not create accounts, instances, backups, services, or files. Rate-limited read probes wait briefly and retry up to two times. Output contains only a combined pass/fail result.

The selection of the fixture owner must be based on prior disposable-host inventory. If no ORM-managed instance is already available for one account while the second account is unconfigured, this test cannot prove resource separation and must not be reported as a passing isolation run. The unit checks in `tests/cpanel-live-isolation-smoke-checks.py` exercise the harness assertions without a cPanel host.

## Current evidence

On 2026-11-20, the current signed ORM `0.1.0-rc.3` package from merged source commit `87331b0` passed the live account identity, query-parameter spoof, and read-only Podman cache assertions. The package updater verified the v3 manifest, WHM registration, broker service state, and socket readiness; the authenticated cPanel entry point matched the signed package. The registered WHM AppConfig was preserved by design. See [`records/2026-11-20-rc3-source-matched-cpanel-smoke.md`](records/2026-11-20-rc3-source-matched-cpanel-smoke.md). This was an HTTP smoke, not an authenticated browser screenshot or visual review.

A live cPanel identity smoke passed on 2026-11-20 against the current entry point and identity classes. The test host was missing the current read-only `ApplicationDiscovery.php` dependency, so that exact file was installed before rerunning the smoke. The existing package manifest and several updater files do not match the current checkout, so this result is not a full install or upgrade validation. See [`records/2026-11-20-cpanel-identity-smoke-after-repair.md`](records/2026-11-20-cpanel-identity-smoke-after-repair.md).

On 2026-11-20, the merged smoke harness also passed exact SSO identity comparison and a read-only query-parameter spoof probe on the same single-account test host. The installed cPanel entry point was not byte-identical to the repository source, and this was not a two-account isolation test. See [`records/2026-11-20-cpanel-query-spoof-smoke.md`](records/2026-11-20-cpanel-query-spoof-smoke.md).

The expanded smoke harness separately tested `user`, `username`, and `account` with two distinct spoof targets on 2026-11-20. The installed page kept the SSO-selected identity for every request. This remains an identity-binding check, not resource-level authorization between two real accounts. See [`records/2026-11-20-cpanel-independent-query-spoof-smoke.md`](records/2026-11-20-cpanel-independent-query-spoof-smoke.md).

Earlier evidence from three private test runs on 2026-11-16 is recorded in [`records/2026-11-16-identity-smoke.md`](records/2026-11-16-identity-smoke.md). That run also observed a Redis container managed by cPanel's Podman integration, but it did not perform Redis/Valkey operations or establish the deployed repository revision.

On 2026-11-20, the opt-in Podman smoke passed on one account with an existing cPanel EA Podman Redis socket. The page's read-only RESP PING fallback reported the socket reachable when the cPanel internal PHP runtime lacked PhpRedis. The candidate PHP files were backed up and restored around this check; no cache keys or values were read. See [`records/2026-11-20-cpanel-podman-live-smoke.md`](records/2026-11-20-cpanel-podman-live-smoke.md).

On 2026-11-17, the repository owner supplied a separate PHP 8.5 CLI/PhpRedis smoke result: the test account connected to its EA Podman Redis Unix socket and `PING` returned `1`. The provenance and exact scope are recorded in [`records/2026-11-17-ea-podman-phpredis-smoke.md`](records/2026-11-17-ea-podman-phpredis-smoke.md). This is a user-supplied result, not a run of the repository smoke harness.

The live two-account broker isolation check passed once on 2026-11-20 on the designated disposable cPanel system; see [`records/2026-11-20-cpanel-two-account-isolation.md`](records/2026-11-20-cpanel-two-account-isolation.md). This single run does not verify fresh installation, the full lifecycle controls, metrics, configuration, restore, migration, recovery, uninstall, reseller ACL behavior, or a supported production matrix. Those remain release gates.

`tests/whm-acl.php` exercises the fail-closed reseller ACL parser with exact-match, missing-`all`, unrelated reseller, malformed record, CRLF, and oversized-input cases. It also checks that privileged WHM controls require a root identity and a valid request guard. This is local policy/parser coverage; it does not establish how a live reseller login is authorized by WHM. Live reseller-ACL behavior remains unverified. Two-account resource isolation has one passing disposable-host run, recorded above.

Other narrowly scoped live test results are recorded separately: the [managed-v1 package upgrade](records/2026-11-20-managed-v1-upgrade.md) passed on one cPanel test system, and the [Jupiter icon registration refresh](records/2026-11-20-cpanel-icon-registration.md) records the accepted flattened-path icon package and sprite regeneration. These checks do not establish host support.

## Authenticated cPanel page visual review

The authenticated Jupiter browser view opened ORM from the cPanel Tools launcher and rendered the cache-instance status, setup preflight, and application-discovery guidance. The sanitized [live page capture](../../screenshots/validation/cpanel-user-preflight-live.png) excludes the browser URL/session path and account/server details; the full temporary capture was deleted. No discovery scan, lifecycle action, or configuration change was performed. See the [visual review record](records/2026-11-21-cpanel-user-page-visual.md). The installed source revision was not established, so this is page-render evidence only.

See the [host compatibility and validation matrix](compatibility-matrix.md) for the remaining scenarios and candidate host combinations, and use the [validation record template](record-template.md) to capture future runs without recording private host or account details.

The test uses cPanel's documented [`create_user_session` single-sign-on flow](https://api.docs.cpanel.net/guides/guide-to-api-authentication/guide-to-api-authentication-single-sign-on).

## WHM security report engine smoke

`tests/whm-live-security-report-engine.php` runs as root with cPanel's PHP CLI on a disposable cPanel & WHM host. It requests the broker's bounded fleet summary, reads normalized ORM journal events, and builds the report in memory. It prints only pass/fail and whether the report is partial. It does not submit the WHM form, write an audit event, consume the one-minute report rate limit, change policy, or read Redis keys.

```sh
/usr/local/cpanel/3rdparty/bin/php tests/whm-live-security-report-engine.php
```

On 2026-11-20, the source-matched rc.3 installation passed the broker, report builder, report-only mode, and audit-source-read checks. The generated report was partial. See [`records/2026-11-20-whm-security-report-engine.md`](records/2026-11-20-whm-security-report-engine.md).

The authenticated form path can be exercised separately with `tests/whm-live-security-report-form.php --confirm-report-write`. This root-only smoke obtains a short-lived WHM SSO session through `whmapi1`, pins HTTPS requests to the local WHM listener, verifies that the root-only form renders, submits a read-only fleet-summary control request, submits the report POST, and checks for its new metadata-only audit event. It intentionally consumes the one-minute report throttle and writes one audit event; it does not change policy, backend selection, Redis/Valkey data, or report thresholds. Its output is limited to sanitized pass/fail diagnostics.

## WHM fixed-diagnostics form smoke

`tests/whm-live-diagnostics-form.php --username=ACCOUNT --confirm-live-reads` exercises eight fixed read-only probes through an authenticated root WHM SSO session, including per-command call and CPU-time counters without command arguments. Use only a disposable ORM-managed Redis account with a running instance. The harness checks the visible root controls, normalized result fields, one success audit record per class, a rapid repeat rejected and audited by the five-second per-account throttle, and an unsupported `flushall` class rejected by the WHM client before it reaches the broker. It waits between classes and does not change configuration or lifecycle state. It sends sixteen read-only diagnostic requests plus one unsupported-class rejection, and prints no account name, host, response body, or diagnostic value.

The host must already have a disposable instance selected for the test. The command is an explicit gate because it sends sixteen authenticated read-only requests and creates success/throttle audit events. Preserve the existing cPanel EA Podman container; remove any temporary ORM direct instance after evidence capture. Passing this single host smoke does not establish production support.

To exercise only the read-only fleet-summary POST without generating a security report or writing an audit event, use `tests/whm-live-security-report-form.php --fleet-summary-only`. The harness waits briefly after the page GET because that request consumes the broker's per-peer `fleet.list` rate slot; this avoids submitting the form against the same one-second rate window. The report-write mode also waits between its summary and report requests because both request the broker's one-per-second `fleet.summary` operation.

To validate a real WHM state-changing POST while preserving effective settings, use `tests/whm-live-security-report-form.php --confirm-policy-roundtrip` on a disposable host. It reads the current report-only thresholds from the authenticated page, temporarily changes one value by one, verifies the saved value, then restores and verifies the original thresholds. This emits metadata-only threshold audit events and briefly changes report severity; it does not enforce policy or change backend selection or Redis/Valkey services. The harness retries restoration if the first update path fails and reports explicitly if restoration cannot be verified.

Use `--fleet-summary-fast` to omit the wait intentionally. This exercises a rapid read-only POST while the per-peer fleet inventory may be rate-limited and asserts that the summary and report form still render. `--confirm-report-fast` runs the same rapid sequence through report generation; it consumes the report throttle and writes a metadata-only audit event.

The initial immediate POST smoke raced the broker's per-peer `fleet.list` rate limit. The report result was generated, but the UI only rendered its controls and results inside the fleet-inventory success branch. After moving the fleet-summary and security-report sections outside that branch, the live fast fleet-summary and report POST smokes both passed; the report audit event was verified. See [`records/2026-11-20-whm-security-report-form.md`](records/2026-11-20-whm-security-report-form.md). The live smoke is HTTP-based and does not replace a browser visual review or the broader host matrix.
