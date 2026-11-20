# Host compatibility and validation matrix

**Last checked against vendor documentation:** 2026-11-20
**ORM support status:** no production host combination has completed the ORM validation gate.

This page separates cPanel & WHM's host-install requirements from ORM's own tested support. A host listed as installable by cPanel is not thereby validated for ORM. The vendor matrix changes over time; consult the linked pages before selecting a disposable test image.

## cPanel & WHM vendor host-install matrix

The following rows summarize cPanel's current new-install documentation. They describe cPanel & WHM eligibility only.

| Operating system | cPanel & WHM vendor requirement | ORM validation |
|---|---|---|
| AlmaLinux 8 | cPanel & WHM 110 or later | Not established |
| AlmaLinux 9 | cPanel & WHM 114 or later | Not established |
| AlmaLinux 10 | cPanel & WHM 132 or later | Not established |
| CloudLinux 7 | Not recommended; cPanel & WHM 112 and later block installation | Not established; exclude from new ORM test targets |
| CloudLinux 8 or 9 | Listed by cPanel; use its current requirements and product-version pages for exact eligibility | Not established |
| CloudLinux 10 | cPanel & WHM 134 or later; convert from AlmaLinux 10 before installing cPanel | Not established |
| Ubuntu 24.04 LTS | Current documented Ubuntu version | Not established |
| Rocky Linux 8 or 9 | cPanel & WHM no longer supports new or existing Rocky Linux installations | Unsupported by the cPanel vendor; do not target |

Sources: [AlmaLinux requirements](https://docs.cpanel.net/installation-guide/system-requirements-almalinux/), [CloudLinux requirements](https://docs.cpanel.net/installation-guide/system-requirements-cloudlinux/), [Ubuntu requirements](https://docs.cpanel.net/installation-guide/system-requirements-ubuntu/), [Rocky Linux deprecation](https://docs.cpanel.net/knowledge-base/cpanel-product/cpanel-deprecation-plan/).

The vendor's [product versions and release process](https://docs.cpanel.net/knowledge-base/cpanel-product/product-versions-and-the-release-process/) lists release channels, LTS versions, and approximate end-of-life dates. Those values change; record the exact cPanel & WHM version and tier for every ORM test run. No cPanel version or release tier is currently established as supported by ORM.

## PHP runtime matrix

The cPanel plugin page executes with cPanel's internal PHP runtime. EasyApache PHP and CloudLinux Alt-PHP are customer-domain runtimes used by applications; they do not establish compatibility of the ORM control-panel page.

| Runtime | Vendor availability | ORM validation |
|---|---|---|
| cPanel internal PHP | cPanel & WHM 130 and later currently include internal PHP 8.4. Older cPanel releases use their release-specific internal runtime. | PHP CI runs on 8.1; compatibility under cPanel's internal PHP has only the limited identity-smoke evidence below. No release matrix established. |
| EasyApache 4 domain PHP | cPanel currently documents PHP 7.4 and PHP 8.1–8.5. | Not validated across versions, extensions, handlers, or socket visibility. These versions are application runtimes, not the ORM page runtime. |
| CloudLinux Alt-PHP / PHP Selector | Versions vary by CloudLinux release. PHP Selector requires CageFS, Alt-PHP, initialized/enabled CageFS, and a compatible handler; consult the current CloudLinux compatibility matrix. | Not validated. ORM socket visibility and client-extension behavior under CageFS/PHP Selector have not been exercised. |

Sources: [cPanel internal PHP](https://docs.cpanel.net/knowledge-base/general-systems-administration/cpanel-php/), [EasyApache PHP versions](https://docs.cpanel.net/ea4/php/about-php/), [CloudLinux PHP Selector requirements](https://docs.cloudlinux.com/cloudlinuxos/cloudlinux_os_components/).

## cPanel theme integration

| Surface | Current package target | ORM validation |
|---|---|---|
| cPanel user interface | Jupiter only. The installer registers the plugin with cPanel's `install_plugin --theme jupiter` flow and places its LiveAPI page under Jupiter's interface directory. The group icon is a 32×32 SVG; the launcher uses a 48×48 SVG with a same-name transparent RGBA PNG fallback. Both SVGs use pixel-space viewBoxes and explicit pixel-space artwork paths for cPanel sprite compatibility. | The installed group and feature SVGs contain the cube paths directly. Install, upgrade, and uninstall synchronously regenerate the theme sprite and align the stylesheet cache URL with its SVG hash. Authenticated browser appearance still needs confirmation. See the [sanitized record](records/2026-11-20-cpanel-icon-registration.md). No theme/version combination is declared supported, and lifecycle behavior remains unvalidated. |
| WHM administrator interface | Native WHM AppConfig registration, separate from the cPanel theme. | No cPanel/WHM version has completed the disposable-host gate. |

cPanel's [plugin registration guide](https://api.docs.cpanel.net/guides/guide-to-cpanel-plugins/guide-to-cpanel-plugins-add-plugins) documents Jupiter group and feature icon sizes and formats. Its [install_plugin reference](https://docs.cpanel.net/whm/scripts/the-install_plugin-script/) describes the theme-specific registration utility. ORM does not claim support for Paper Lantern or other cPanel themes.

## ORM disposable-host matrix

The rows below are candidate validation targets, not supported configurations. Start from a clean, disposable server. Record exact versions and features before changing the host.

| Candidate host combination | Required evidence | Status |
|---|---|---|
| AlmaLinux 9 + cPanel & WHM 134 LTS | Install, account boundary, WHM ACL, lifecycle, backup/restore, migration, recovery, uninstall | Not run |
| AlmaLinux 10.3 + cPanel & WHM 138.0 RELEASE build 27 | Same lifecycle and security scenarios; confirm package/service behavior | Partial: signed rc.3 update and source-matched cPanel page passed; authenticated identity, query-spoof, and read-only Podman PING passed. Two-account isolation, WHM ACL, web-form lifecycle, security, recovery, uninstall, and broader feature scenarios remain unverified. |
| Ubuntu 24.04 LTS + a currently supported cPanel release | Installer prerequisites, registration, service lifecycle, backup/restore, uninstall | Not run |
| CloudLinux 9 + a currently supported cPanel release | Base installation first, then CageFS/PHP Selector, Alt-PHP, handler, domain socket visibility and lifecycle | Not run |
| CloudLinux 10 + cPanel & WHM 134 or later | Supported conversion/install route, CageFS/PHP Selector, Alt-PHP, handler, domain socket visibility and lifecycle | Not run |

Do not advertise any row as supported until a completed, reviewable validation record exists for that exact combination and the release gate is updated.

## Scenario coverage and evidence status

| Scenario | Existing automated evidence | Disposable cPanel evidence |
|---|---|---|
| Fresh install | Linux CI runs the installer in an isolated mock cPanel root and checks deployed files, manifest, AppConfig, service state, instance-root permissions, and rollback after registration failure | Not recorded |
| Upgrade and uninstall | Linux CI mocks identity-v1 and exact managed-v1 upgrades, registration failures, rollback, interruption recovery, and uninstall paths | Exact managed-v1 upgrade passed on one owner-designated test cPanel system; see the [sanitized record](records/2026-11-20-managed-v1-upgrade.md). Other upgrade baselines and uninstall remain unrecorded on cPanel. |
| Signed source-matched update preview and apply | Linux tests cover signature, digest, manifest, conflict, normalization, apply, and recovery contracts | Preview and apply passed on AlmaLinux 10.3 / cPanel 138.0 RELEASE build 27 using a temporary test signing key. The rc.2 run reported one reviewed CRLF-only normalization, two additions, 18 replacements, and 30 unchanged files. The rc.3 run advanced the package from `0.1.0-rc.2` to `0.1.0-rc.3`; its preview had zero conflicts, moves, normalizations, or retirements. The updater changed the package library/version and preserved the cPanel-normalized WHM AppConfig registration. Recovery was exercised in Linux CI, not by interrupting the live host. See the [rc.2 apply record](records/2026-11-20-source-matched-update-apply.md) and [rc.3 source-matched smoke record](records/2026-11-20-rc3-source-matched-cpanel-smoke.md). |
| Account identity | Live smoke checks LiveAPI identity against the local broker | The current signed rc.3 cPanel entry point passed authenticated SSO identity verification after update from source commit `87331b0`; see the [source-matched smoke record](records/2026-11-20-rc3-source-matched-cpanel-smoke.md). Earlier partial identity runs remain recorded separately. |
| Account boundary and WHM ACL | Broker and PHP tests cover peer identity and root-only request paths | One-account exact SSO identity and `user`/`username`/`account` query-spoof resistance passed against the source-matched rc.3 page. Two-account resource isolation and WHM ACL behavior remain unrecorded. See the [source-matched smoke record](records/2026-11-20-rc3-source-matched-cpanel-smoke.md). |
| Redis/Valkey discovery and lifecycle | Broker tests exercise service and backend operations with fixtures | The source-matched rc.3 cPanel page discovered and PINGed the existing account-owned Redis socket. A separate account-context PHP 8.5 CLI smoke created a disposable EA Valkey container and exercised ORM start, stop, start, and restart; each state and bounded PING was verified. Cleanup removed the temporary container and its backup directory. The current web-form/session lifecycle controls remain untested. See the [rc.3 discovery record](records/2026-11-20-rc3-source-matched-cpanel-smoke.md), [prior discovery record](records/2026-11-20-cpanel-podman-live-smoke.md), and [lifecycle record](records/2026-11-20-cpanel-podman-lifecycle-smoke.md). |
| WHM security-report counter fields | Broker tests cover monotonic deltas, resets, gaps, and a missing optional auth counter while preserving supported rates | Read-only Redis 6.2.24 `INFO` probe found eviction/command fields and no optional ACL auth field. On the source-matched rc.3 installation, the live broker summary, report builder, report-only mode, and audit-source read passed; the generated report was partial. Root SSO and report form rendered, and the report POST produced a new audit event, but the WHM response lacked ORM report markup; end-user report rendering remains unverified. Valkey remains untested. See the [counter probe](records/2026-11-20-redis-6.2-security-counter-probe.md), [live report-engine record](records/2026-11-20-whm-security-report-engine.md), and [live report-form record](records/2026-11-20-whm-security-report-form.md). |
| Backup and restore | Broker tests exercise selected snapshots, validation, service restart, and rollback with fixtures | Not recorded |
| Redis-to-Valkey migration | Broker tests exercise version gates, validation, success, and rollback with fixtures | Not recorded |
| WHM recovery | Broker and fleet tests cover read-only scans and the fixed start repair | Not recorded |
| Optional AUTH defaults and lifecycle | Broker fixtures cover disabled-by-default status, verified enable/rotation/disable, and config preservation | Not recorded |
| AUTH restart failure and rollback | Broker fixtures cover failed PING verification and restoration of the prior auth state; PHP tests cover the cPanel action/response contract | Not recorded on cPanel |
| AUTH credential disclosure | Broker/PHP diagnostics tests check secret exclusion from status, metrics, diagnostics, audit metadata, and helper output | Not recorded on cPanel |
| Missing binaries / bad permissions | Guard and broker tests cover selected preflight and permission failures | Not recorded |
| Full disk / ENOSPC | Perl broker test injects ENOSPC after a partial configuration write and checks fail-closed cleanup; this simulates the write error without filling a filesystem | Not recorded |
| Stale metrics | Broker and PHP tests cover stale sample behavior | Not recorded |
| Failed rollback | Packaging and broker fixtures cover selected rollback failures | Not recorded on cPanel |

CI and fixture results are valuable repository evidence. They do not prove behavior across real cPanel releases, OS images, CloudLinux features, PHP handlers, server package layouts, or authentication with installed Redis/Valkey CLI processes. In particular, AUTH CLI environment handling and secret display in a real authenticated cPanel session still need host validation.

## Validation record requirements

Use the [disposable-host validation record template](record-template.md). Record the tested commit, OS, cPanel version and tier, PHP runtime and handler, CloudLinux/CageFS/PHP Selector state, scenario results, and failure-injection results. Do not record hostnames, IP addresses, account names, credentials, API tokens, session URLs, private keys, or raw logs. Keep private operational details in the owner's private test record, not in this repository or shared project memory.
