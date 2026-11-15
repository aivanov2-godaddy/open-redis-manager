# CloudLinux and PHP runtime integration

Redis server installation and Redis client availability inside a customer's PHP runtime are separate layers. The cPanel plugin manages the service; CloudLinux PHP Selector controls which extensions a PHP runtime can load.

## Planned support checklist

- Detect CloudLinux and its PHP Selector features without assuming all servers use the same runtime.
- Tell the user/admin which PHP versions need the Redis extension enabled.
- Where the platform uses CageFS, validate whether the newly enabled extension is visible in the account's isolated runtime and perform only a supported targeted refresh.
- On EasyApache systems, identify the extension package matching each enabled PHP version.
- Report extension state and useful next steps without exposing root-only paths to an account user.

The exact commands and OS matrix must be verified against current cPanel and CloudLinux releases before production implementation. The local prototype does not change runtime configuration.
