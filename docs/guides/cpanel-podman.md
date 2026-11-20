# cPanel Redis and Valkey containers

ORM supports two account connection paths:

- **Direct ORM-managed instance:** ORM provisions a Redis or Valkey process from an installed host binary, owns its systemd unit and account-private socket, and offers the lifecycle, configuration, metrics, and snapshot controls implemented for ORM instances.
- **Existing cPanel EA Podman cache:** ORM discovers Redis or Valkey containers installed for the authenticated cPanel account, can start, stop, or restart them through cPanel's EA Podman script, performs a read-only PING when the current PHP runtime has PhpRedis, and generates application connection settings. cPanel remains responsible for package configuration and container backups.

The cPanel page scans only the authenticated account's `~/ea-podman.d` directory. It accepts only account-matching EA Redis/Valkey container names and verifies ownership and non-writable directory modes. Existing containers appear when stopped as well as running; Redis uses `redis.sock`, Valkey uses `valkey.sock`. Health probes return only reachability and a validated server version.

## Requirements and use

cPanel documents Redis 6.2 and Valkey 7.2 as EasyApache 4 container packages. EA4 containers must be enabled on a supported host. Their setup commands run in the cPanel account context, and the account requires Normal Shell access rather than Jailed Shell. See cPanel's [EasyApache 4 Containers](https://docs.cpanel.net/ea4/containers/easyapache-4-containers/), [Redis via Containers](https://docs.cpanel.net/ea4/containers/redis-via-containers/), [Valkey via Containers](https://docs.cpanel.net/ea4/containers/valkey-via-containers/), and [`ea-podman` script](https://docs.cpanel.net/ea4/containers/the-ea-podman-script/) guides.

After cPanel has installed a container for the account, open **Open Redis Manager** in cPanel. The **Existing cPanel Podman caches** section shows its status, account-owned socket when present, and (when recognized) the server version. Use Start for a stopped container, or Restart and Stop while its socket exists. Open an example to copy socket settings for PhpRedis, WordPress/WooCommerce, LiteSpeed Cache, Laravel, Magento/Adobe Commerce, Node.js, or Python.

Lifecycle actions are available only to the authenticated owner of an existing container with a normal, non-jailed shell. ORM calls the fixed `/usr/local/cpanel/scripts/ea-podman` program as that cPanel account with only `start`, `stop`, or `restart`, and reports bounded, sanitized outcomes. It does not accept arbitrary commands or paths, and does not install, uninstall, upgrade, or reconfigure containers. If ORM cannot verify the account identity, shell, directory ownership, or container name, it hides the candidate or rejects the action. If PhpRedis is unavailable, ORM labels health **not checked**. A failed PING does not trigger a lifecycle action.

Use cPanel's own `ea-podman` tools to install, upgrade, back up, or remove these containers. ORM's create/restore snapshots apply only to ORM-managed direct instances and do not operate on cPanel Podman data.

## Verified test-host evidence

On 2026-11-16, a disposable cPanel test account used the EasyApache PHP 8.5 CLI and PhpRedis to connect to its EA Podman Redis 6.2.24 Unix socket; `PING` returned success. This confirms the tested account's PHP extension and socket access work together. It does not validate every PHP handler, CageFS/PHP Selector configuration, Valkey, or the full ORM installation lifecycle. Host, account, and socket identifiers are intentionally omitted.

On 2026-11-20, the merged lifecycle manager source candidate was exercised from the test account's EasyApache PHP 8.5 CLI against a new, temporary EA Valkey container. Start, stop, start, and restart each completed, and discovery reported the expected socket state and reachable PING. The temporary container and its uninstall backup were removed; the existing Redis cache remained reachable. This did not exercise the authenticated cPanel web form or establish support for other hosts. See the [sanitized lifecycle record](../validation/records/2026-11-20-cpanel-podman-lifecycle-smoke.md).

On 2026-11-21, the source-matched cPanel page passed an authenticated SSO form smoke against the existing test Redis container. The smoke submitted stop, start, and restart, verified each fresh page's socket state, restored the original running state, and confirmed a PhpRedis PING. This is one host/account result; it does not validate Valkey web actions, cross-account web access, or the broader support matrix. See the [sanitized web lifecycle record](../validation/records/2026-11-21-cpanel-podman-web-lifecycle.md).
