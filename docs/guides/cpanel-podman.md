# cPanel Redis and Valkey containers

ORM supports two account connection paths:

- **Direct ORM-managed instance:** ORM provisions a Redis or Valkey process from an installed host binary, owns its systemd unit and account-private socket, and offers the lifecycle, configuration, metrics, and snapshot controls implemented for ORM instances.
- **Existing cPanel EA Podman cache:** ORM discovers a Redis or Valkey socket already installed for the authenticated cPanel account, performs a read-only PING when the current PHP runtime has PhpRedis, and generates application connection settings. cPanel remains responsible for the container lifecycle, package configuration, and container backups.

The cPanel page scans only the authenticated account's `~/ea-podman.d` directory. It accepts only account-matching EA Redis/Valkey container names, checks ownership and non-writable directory modes, and requires an account-owned Unix socket. It does not accept a socket path from a request, list another account's containers, read key names or values, or change a container. Redis uses `redis.sock`; Valkey uses `valkey.sock`. The health probe returns only reachability and a validated server version.

## Requirements and use

cPanel documents Redis 6.2 and Valkey 7.2 as EasyApache 4 container packages. EA4 containers must be enabled on a supported host. Their setup commands run in the cPanel account context, and the account requires Normal Shell access rather than Jailed Shell. See cPanel's [EasyApache 4 Containers](https://docs.cpanel.net/ea4/containers/easyapache-4-containers/), [Redis via Containers](https://docs.cpanel.net/ea4/containers/redis-via-containers/), [Valkey via Containers](https://docs.cpanel.net/ea4/containers/valkey-via-containers/), and [`ea-podman` script](https://docs.cpanel.net/ea4/containers/the-ea-podman-script/) guides.

After cPanel has installed and started a container for the account, open **Open Redis Manager** in cPanel. The **Existing cPanel Podman caches** section shows the account-owned socket, probe status, and (when recognized) the server version. Open an example to copy socket settings for PhpRedis, WordPress/WooCommerce, LiteSpeed Cache, Laravel, Magento/Adobe Commerce, Node.js, or Python.

If ORM cannot verify the current cPanel account identity, directory ownership, socket type, or container name, it hides that candidate. If PhpRedis is unavailable, ORM can still show a verified socket and connection examples but labels its health state **not checked**. If a PING fails, ORM reports the probe unavailable; it does not start or repair the cPanel container.

Use cPanel's own `ea-podman` commands to install, start, stop, restart, upgrade, back up, or remove these containers. ORM's create/restore snapshots and lifecycle actions apply only to ORM-managed direct instances and do not operate on cPanel Podman data.
