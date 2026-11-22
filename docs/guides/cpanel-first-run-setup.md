# cPanel first-run backend setup

The authenticated cPanel page shows this wizard when the account has no ORM-managed instance and no verified account-owned cPanel EA Podman cache. ORM distinguishes an empty account inventory from a missing, unsafe, or unreadable inventory; it does not treat an unknown result as “not installed.” The wizard remains available so the user can check the native backend if Podman discovery is unknown, but it withholds Podman install steps unless the inventory is verified empty. A verified existing account-owned cache suppresses duplicate first-run setup.

Static previews: [backend choice](../../screenshots/cpanel-backend-setup.png) and [EA Podman package steps](../../screenshots/cpanel-podman-setup-wizard.png). They use synthetic data and are not live cPanel captures.

## Choose a backend path

### Native service

The native path uses an installed host Redis or Valkey server and matching CLI binaries to provision an ORM-managed, account-scoped service. The wizard checks fixed standard binary paths and reports recognized server versions. It distinguishes a complete pair from a server-only or CLI-only installation. No matching pair means only that ORM did not find both binaries in those locations; it does not prove that Redis is absent from the host.

When native binaries are missing or incomplete, the wizard gives the account owner a short administrator checklist: install the server and matching CLI from a trusted operating-system repository, select the detected backend in WHM, allow the cPanel package in provider policy, and return to recheck. The hosting administrator must install the supported native package and select the default backend in WHM before provisioning. The cPanel account cannot install host packages or change WHM policy. Provisioning remains subject to provider package enablement, resource limits, and reseller policy in the root-owned broker.

### cPanel EA Podman

The wizard verifies the host's `/etc/os-release` ID when readable. cPanel documents EA Podman containers for AlmaLinux, Rocky Linux, and Ubuntu; CloudLinux/CageFS container installation is not supported by this integration. It also checks that the account has a normal shell and runs the fixed, read-only `ea-podman avail` command under the authenticated cPanel account. The inventory response is bounded to 8 KiB and four seconds.

When the account inventory advertises an approved package, the wizard shows its fixed account-scoped command:

```sh
/usr/local/cpanel/scripts/ea-podman install ea-redis62
```

or:

```sh
/usr/local/cpanel/scripts/ea-podman install ea-valkey72
```

Run the command in cPanel Terminal or SSH as the cPanel account, then return to ORM and choose **Check again**. ORM then verifies the account-owned container directory and socket and presents connection examples. ORM does not run the package installation request in a web request because the first installation can download an image and exceed cPanel/PHP request timeouts.

## Host prerequisites and unknown states

The cPanel administrator must install and configure the EasyApache 4 container support packages, ensure the server uses a supported operating system, and enable user namespaces. ORM does not change host packages, kernel namespace policy, account shells, or CloudLinux/CageFS configuration. The setup guide links to cPanel's official administrator instructions when the account-level tool or packages are missing.

If `/etc/os-release` is unreadable or has an unrecognized ID, the host is shown as unknown and must be verified by the administrator. ORM does not probe user namespace availability from the cPanel page. A missing `ea-podman` tool, unsupported shell, failed inventory command, timeout, or unrecognized inventory is reported separately from an account with no containers. A package omitted from a recognized `avail` inventory is shown as not listed, not as proof that no Redis-compatible server exists anywhere on the host.

References: cPanel's [EasyApache 4 Containers](https://docs.cpanel.net/ea4/containers/easyapache-4-containers/), [ea-podman Script](https://docs.cpanel.net/ea4/containers/the-ea-podman-script/), [Redis via Containers](https://docs.cpanel.net/ea4/containers/redis-via-containers/), [Valkey via Containers](https://docs.cpanel.net/ea4/containers/valkey-via-containers/), and [User Namespaces and Podman](https://docs.cpanel.net/knowledge-base/security/user-namespaces-and-podman/).
