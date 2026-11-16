# Implement a signed, versioned WHM updater

Live issue: [#70](https://github.com/aivanov2-godaddy/open-redis-manager/issues/70), milestone 0.2.0.

Build a general transactional updater beyond the identity-v1 compatibility bridge described in the [update lifecycle guide](../../docs/guides/update-lifecycle.md).

Acceptance:

- Verify signed release metadata and artifacts plus compatibility before mutation.
- Preview file and migration actions; serialize updates and preserve account data and backend choice.
- Snapshot ORM-owned state, migrate transactionally, roll back on failure, and provide manual recovery guidance.
- Audit outcomes and verify version, registration, and service health after updating.
- Add failure-injection tests; do not claim host support without disposable validation.
