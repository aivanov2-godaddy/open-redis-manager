# Reference release and roadmap summary

This page summarizes the public documentation and update pages for the commercial cPanel Redis Manager reference product. It records what those pages say; it is not ORM's changelog, an independent verification of the vendor software, or a commitment to implement those plans.

## Current release shown by the source

The reference documentation and update page displayed **v2.6.11** when reviewed on 2026-11-16. The documentation describes v2.6.8–v2.6.11 as a stability series covering configuration ownership and live memory changes, preserving useful metrics under load, avoiding latency spikes from automatic RDB snapshots, and expanding redacted diagnostics. It also describes report-only abuse findings, stronger AUTH protections, WHMCS licensing automation, and a faster WHM dashboard as v2.6.x capabilities. These are vendor claims, not ORM behavior.

The vendor's [update page](https://cpanelredismanager.com/upgrade.php) describes release visibility and an in-WHM update workflow. ORM now has a root-only WHM workflow for manually staged, locally signed releases, with explicit preview and confirmation, asynchronous apply, and bounded recovery status. It does not fetch updates automatically, and release signing plus live cPanel validation remain open. See [ORM's update lifecycle](guides/update-lifecycle.md) for its exact limits.

## Reference release phases

| Version family | Capability themes described by the reference documentation |
|---|---|
| 2.0.x | Per-account service isolation, port and credential setup, installer and migration foundation. |
| 2.1.x | WHM dashboard, account controls, backups, recovery and hardening. |
| 2.2.x | cPanel monitoring, presets, backup/restore, configuration and health handling. |
| 2.3.x | Package/reseller groundwork, branding, usage history, release hardening and observability improvements. |
| 2.4.x | Redis/Valkey abstraction, OS-aware fresh-install choice, WHM backend selection, diagnostics, recovery and migration readiness. |
| 2.5.x | Package enforcement, reseller quotas, exposure levels, provider hooks and explicit migration. |
| 2.6.x | Abuse reporting, AUTH protections, licensing automation, dashboard performance, branding and stability fixes. |

## Forward roadmap shown by the source

The reference [documentation roadmap](https://cpanelredismanager.com/documentation.php) and [update page](https://cpanelredismanager.com/upgrade.php) describe the following planned phases. The documentation labels the next phase v2.7.x; the update page calls it v2.7.0.

| Version family | Planned themes described by the reference |
|---|---|
| 2.7.x | Observability and debugging: deeper graphs, slow-log and command visibility, debug mode, security summaries, stronger health scoring and audit visibility. |
| 2.8.x | Background workers, restart backoff, auto-healing, orphan cleanup and system maintenance automation. |
| 2.9.x | Profiles and configuration bundles, backup rollback and integrity improvements, cross-server export/import, and signed configuration validation. |
| 2.10.x | REST API, webhooks and automation events, Redis version management, and external Redis integration. |
| 3.0.x | Shared architecture, DirectAdmin support, and cluster, Sentinel and scaling-oriented deployment. |

The reference documentation also describes provider hook events for backend changes, denied access, quota limits and billing automation. This is a vendor-described capability, not evidence that ORM implements it. ORM tracks a separately designed, optional signed event adapter in [issue #143](https://github.com/aivanov2-godaddy/open-redis-manager/issues/143); it must not couple core service control to WHMCS or send secrets and Redis data in event payloads.

## ORM planning rule

ORM's implementation roadmap is maintained separately under [`project/README.md`](../project/README.md), and its verified feature state is in the [feature catalog](features/catalog.md). Reference ideas inform discovery; they do not establish implementation, compatibility, or production readiness. ORM release claims must be backed by repository and environment evidence. In particular, migration code exists but still requires disposable-host validation, and a general in-panel updater remains unimplemented.
