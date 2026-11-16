# Host compatibility and validation matrix

**Last checked against vendor documentation:** 2026-11-16
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

## ORM disposable-host matrix

The rows below are candidate validation targets, not supported configurations. Start from a clean, disposable server. Record exact versions and features before changing the host.

| Candidate host combination | Required evidence | Status |
|---|---|---|
| AlmaLinux 9 + cPanel & WHM 134 LTS | Install, account boundary, WHM ACL, lifecycle, backup/restore, migration, recovery, uninstall | Not run |
| AlmaLinux 10 + cPanel & WHM 134 or later | Same lifecycle and security scenarios; confirm package/service behavior | Not run |
| Ubuntu 24.04 LTS + a currently supported cPanel release | Installer prerequisites, registration, service lifecycle, backup/restore, uninstall | Not run |
| CloudLinux 9 + a currently supported cPanel release | Base installation first, then CageFS/PHP Selector, Alt-PHP, handler, domain socket visibility and lifecycle | Not run |
| CloudLinux 10 + cPanel & WHM 134 or later | Supported conversion/install route, CageFS/PHP Selector, Alt-PHP, handler, domain socket visibility and lifecycle | Not run |

Do not advertise any row as supported until a completed, reviewable validation record exists for that exact combination and the release gate is updated.

## Scenario coverage and evidence status

| Scenario | Existing automated evidence | Disposable cPanel evidence |
|---|---|---|
| Fresh install | Linux CI runs the installer in an isolated mock cPanel root and checks deployed files, manifest, AppConfig, service state, instance-root permissions, and rollback after registration failure | Not recorded |
| Upgrade and uninstall | Linux CI mocks the identity-v1 upgrade, registration failures, rollback, and uninstall paths | Not recorded |
| Account identity | Live smoke checks LiveAPI identity against the local broker | Passed in two private test runs; latest run was read-only and the deployed source revision was not established |
| Account boundary and WHM ACL | Broker and PHP tests cover peer identity and root-only request paths | Not recorded across the matrix |
| Redis/Valkey lifecycle | Broker tests exercise service and backend operations with fixtures | Not run; read-only discovery on the latest private test environment did not detect Redis or Valkey at the supported common paths |
| Backup and restore | Broker tests exercise selected snapshots, validation, service restart, and rollback with fixtures | Not recorded |
| Redis-to-Valkey migration | Broker tests exercise version gates, validation, success, and rollback with fixtures | Not recorded |
| WHM recovery | Broker and fleet tests cover read-only scans and the fixed start repair | Not recorded |
| Missing binaries / bad permissions | Guard and broker tests cover selected preflight and permission failures | Not recorded |
| Full disk / ENOSPC | Perl broker test injects ENOSPC after a partial configuration write and checks fail-closed cleanup; this simulates the write error without filling a filesystem | Not recorded |
| Stale metrics | Broker and PHP tests cover stale sample behavior | Not recorded |
| Failed rollback | Packaging and broker fixtures cover selected rollback failures | Not recorded on cPanel |

CI and fixture results are valuable repository evidence. They do not prove behavior across real cPanel releases, OS images, CloudLinux features, PHP handlers, or server package layouts.

## Validation record requirements

Use the [disposable-host validation record template](record-template.md). Record the tested commit, OS, cPanel version and tier, PHP runtime and handler, CloudLinux/CageFS/PHP Selector state, scenario results, and failure-injection results. Do not record hostnames, IP addresses, account names, credentials, API tokens, session URLs, private keys, or raw logs. Keep private operational details in the owner's private test record, not in this repository or shared project memory.
