# Contributing

Thanks for helping improve Open Redis Manager (ORM).

## Before opening an issue or pull request

- Check whether the report is already tracked in GitHub.
- Never include credentials, customer data, private logs, or server-specific secrets.
- Describe which feature is implemented versus still mocked; the current `index.php` screens are demonstration-only.
- For control-plane work, state the supported cPanel/WHM and operating-system environment and include safe, redacted validation evidence.

## Pull requests

Keep each change focused and update the relevant docs. Privileged service actions need explicit authorization checks, input validation, CSRF protection, secret redaction, and a recovery path. Do not add shell command interpolation to request handlers. Do not claim production readiness based on the visual prototype.

## Security reports

Please follow [`SECURITY.md`](SECURITY.md) for vulnerabilities. Avoid public disclosure of exploitable details before maintainers have a chance to respond.
