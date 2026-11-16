# Add a WHM audit viewer and export

Live issue: [#69](https://github.com/aivanov2-godaddy/open-redis-manager/issues/69), milestone 0.2.0.

Show fixed-metadata ORM broker and policy events in a root-only WHM page.

Acceptance:

- Enforce the WHM ACL and CSRF protection for mutations.
- Provide bounded date, account, action, and result filters plus sanitized export.
- Exclude secrets, Redis keys/values, raw commands, and private host details.
- Explain audit-source gaps and partial records.
- Test access control, filtering, pagination, and redaction.
