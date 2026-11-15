# Reference FAQ summary

The public FAQ addresses the following questions. Answers here summarize the reference product's public position and should not be read as ORM guarantees.

| Question | Summary of the public answer |
|---|---|
| Why use Redis along with MySQL tuning? | It can serve repeated, cached reads from memory instead of asking the database each time. |
| How can Redis affect performance? | It may reduce latency and repeated queries for correctly integrated cache and session workloads. |
| What is Valkey? | A Redis-compatible open-source in-memory server maintained as a Linux Foundation project. |
| When does the site choose Valkey? | It says new installs detect OS/package support; newer major OS lines choose Valkey, while existing Redis remains unchanged unless an administrator acts. Exact matrix can change; check current vendor documentation before applying it elsewhere. |
| Who is the product for? | Site owners, developers, sysadmins, agencies and hosting providers running cPanel/WHM. |
| How does it compare with manual setup? | The page claims integrated deployment, monitoring, backups, recovery and provider controls. |
| Can a provider brand/resell the UI? | The site describes branding, package policy, reseller quotas and exposure levels. |
| Can Redis migrate to Valkey? | It describes explicit per-account snapshot, switch, validation and automatic rollback. |
| Is root required? | The vendor states installation and server-level maintenance need root access. |
| What is included/pricing? | The commercial product lists cPanel and WHM features, updates, support and docs under a per-server license. The site showed $4.95 monthly and $49.50 yearly when reviewed; these are vendor prices, not ORM pricing. |
| Does the product make applications cache automatically? | No. The application needs a compatible Redis client and must be configured with the instance connection details. |
| Is it WordPress-only? | No; examples include Laravel, Magento, custom PHP, APIs, forums and business applications. |
| What can the cPanel user do? | View connection details, operate the account instance, monitor it, configure presets and use backup/restore. |
| What can a WHM admin do? | Manage accounts, command access, metrics, backups, recovery, provider settings, quotas, branding and backend selection. |
| Is the site version live? | The site says its public version is fetched from a release mirror. |
