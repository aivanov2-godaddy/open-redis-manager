# Magento

Magento and Adobe Commerce backend support changes by release. The currently published [Adobe cache backend reference](https://experienceleague.adobe.com/en/docs/commerce-operations/configuration-guide/cache/cache-options) marks Redis unsupported for version 2.4.9 and specified later patch releases, and directs those versions to Valkey. Older supported releases may use a Redis backend class; `Cm_Cache_Backend_Redis` is deprecated in the current Adobe guidance.

Before connecting an installation:

1. Check the exact Magento/Adobe Commerce release and deployment type.
2. Use Adobe's release-specific backend matrix and configuration command. For on-premises installations, Adobe recommends its CLI configuration path for initial setup; Cloud deployments generate `env.php` from deployment variables and should not be hand-edited.
3. Enter the ORM endpoint values only through that supported configuration path.
4. Back up the existing configuration and use the application's deployment and cache-validation procedure.

Do not apply an old `env.php` snippet to a newer release. The file can contain other application secrets and should not be attached to support reports.
