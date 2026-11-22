# WHM security report visual review

## Scope

This record covers one authenticated visual review of the WHM security and abuse report on a disposable cPanel test host. It does not establish general cPanel/WHM, operating-system, Redis, Valkey, or EA Podman support.

## Environment and actions

- Platform: cPanel & WHM 138.0 (build 27), one owner-designated test host. The host name, address, account names, and credentials are intentionally omitted.
- Authentication: fresh WHM SSO session; the report form was submitted with its normal authenticated POST flow.
- Result: HTTP 200 rendered a new report with explicit partial-evidence status and unknown findings. A normalized metadata-only `security.report` audit event was verified. The request consumed the existing one-minute report throttle.
- Side effects: no thresholds, backend policy, Redis/Valkey services, account configuration, keys, values, or secrets were changed or read. The test did not run an installer, start/stop a service, or enable scheduled collection.

## Source and restoration evidence

The styled WHM page staged for the screenshot had SHA-256 `A0434C5E5AEEC5645918B0B9D4DA0F066A2E933BAC077A43AAD5C24CD7AFF89C`. The unchanged `WhmSecurityReport.php` engine had SHA-256 `451E495486364D589EC20F054B36D83473C487EB010E144F1945E65911FFE9C3`.

After capture, the installed WHM page was restored from the committed baseline and verified at SHA-256 `A61ABDB72AF7A4B530CFC142D9FE7A90E7CF980DCCA3B982B90DB8AACE504691`, owned by `root:root` with mode `0644`. The temporary staged page was removed. No host-specific data or credentials were added to this repository.

## Visual result

The authenticated report section was reviewed at a 1440-pixel viewport. The saved section capture is [whm-security-report-live.png](../../../screenshots/validation/whm-security-report-live.png), 1160 × 1007 pixels, SHA-256 `39E1B13910E21F5740096403E57DCF75870B7D8567C4E720513030519FE3933B`.

The heading and report-only boundary, grouped threshold controls, generate action, report timestamp, partial-evidence state, and finding cards were visible without clipping. Unavailable values were labeled unknown. The image contains generic aggregate findings and no host, account, endpoint, Redis data, or credentials.

## Limits and follow-up

This is a one-host visual review of the report response; it does not verify every report scenario or the host compatibility matrix. Broader supported-version/host coverage, host-wide Podman coverage, and additional live unavailable/partial scenarios remain open. Fixture coverage and the separate [EA Podman report integration record](2026-11-22-ea-podman-security-report-live.md) provide other evidence but do not widen this visual review's scope.
