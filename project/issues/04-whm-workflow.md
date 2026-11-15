# Implement WHM fleet operations and recovery

## Goal
Provide administrators with fleet visibility and scoped maintenance operations.

## Acceptance criteria
- Account search/filter covers configured, running, stopped and unhealthy services.
- Authorized operators can control a selected account and see the result.
- CLI surface uses a small allowlist by default and records actor/account/command class.
- Recovery scans before proposing repairs and only changes selected affected accounts.
- Audit records include success/failure and omit secrets.
- Backend health and migration readiness are visible without implicit migration.
