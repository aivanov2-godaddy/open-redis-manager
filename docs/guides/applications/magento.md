# Magento

Magento and Adobe Commerce backend support changes by release. The currently published [Adobe cache backend reference](https://experienceleague.adobe.com/en/docs/commerce-operations/configuration-guide/cache/cache-options) marks Redis unsupported for version 2.4.9 and specified later patch releases, and directs those versions to Valkey. Older supported releases may use a Redis backend class; `Cm_Cache_Backend_Redis` is deprecated in the current Adobe guidance.

Adobe Commerce's on-premises `setup:config:set` tooling accepts an absolute Unix socket path and port `0`. The supported backend name and command-line flags depend on the exact release: Redis tooling applies only to supported older releases, while Valkey is the supported backend for Commerce 2.4.9 and listed later patch releases. Cloud deployments must use their deployment configuration system instead of editing `env.php`.

For an on-premises installation, use the ORM socket path as the server and port `0`. Assign distinct database numbers for default cache, page cache and sessions when those layers share an instance; ORM's shown database value `0` applies to a single cache. AUTH is off by default; if enabled in ORM, set the generated password using the release-specific supported configuration path. Do not paste a copied shell command until you confirm the exact version and selected backend.

Before connecting an installation:

1. Check the exact Magento/Adobe Commerce release and deployment type.
2. Use Adobe's release-specific backend matrix and configuration command. For on-premises installations, Adobe recommends its CLI configuration path for initial setup; Cloud deployments generate `env.php` from deployment variables and should not be hand-edited.
3. Enter the ORM socket path only through that supported configuration path; choose the Redis or Valkey command family that matches the installed release.
4. Back up the existing configuration and use the application's deployment and cache-validation procedure.

Do not apply an old `env.php` snippet to a newer release. The file can contain other application secrets and should not be attached to support reports.
