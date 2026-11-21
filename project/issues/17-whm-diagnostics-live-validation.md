# Issue: Validate selectable WHM diagnostics on disposable cPanel

Live issue: [#161](https://github.com/aivanov2-godaddy/open-redis-manager/issues/161), milestone 0.2.0.

## Goal

Validate the merged fixed-command WHM diagnostics on one owner-designated disposable cPanel host using an exact-source signed validation candidate.

## Acceptance criteria

- Build from a clean merged commit and use a temporary test-only key; never copy private signing material to the host or repository.
- Review and apply the candidate through the documented conflict-free signed update flow.
- Exercise all six fixed diagnostic classes in root WHM against a disposable ORM-managed Redis instance.
- Verify exact bounded outputs, account scope, five-second rate limiting, class-specific audit entries, root authorization, and rejection of arbitrary command text.
- Preserve pre-existing cPanel EA Podman state and remove the temporary direct ORM instance after testing.
- Add a sanitized source-bound record and actual WHM screenshot, with no hostnames, domains, account names, credentials, or raw command output.
- Keep overall host support marked NOT ESTABLISHED.
