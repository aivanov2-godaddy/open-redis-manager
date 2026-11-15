# Security policy

ORM is an early prototype. It is not ready for installation as a privileged cPanel/WHM plugin.

Pull requests and pushes run Gitleaks against their changed commits. The repository configuration extends the default rules with a check for committed SSH destinations, since test hostnames are environment-specific. The workflow redacts findings and disables PR comments, summaries, and uploaded reports so secrets are not copied into public review output. Run the same scanner locally before publishing changes when available.

## Reporting a vulnerability

Do not publish exploit details, credentials, customer data, or an unredacted server capture in a public issue. Contact the repository maintainers privately through the GitHub security advisory/reporting feature when available. Include the affected revision, product surface, impact and a minimal reproduction with secrets removed.

## Supported versions

There are no production-supported releases yet. Security fixes will be tracked against the active development branch until the first release is declared.
