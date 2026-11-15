# Reference release and roadmap summary

This page records the public version history themes on the reference documentation as observed on 2026-11-15. It is not ORM's changelog or a statement that this repository has those features.

## Reference release shown

The marketing and docs pages displayed version 2.6.11. The docs describe a recent stability series around configuration ownership, preserving usable metrics under load, resource pressure behavior, expanded redacted diagnostics and applying memory defaults to newly created instances.

## Major product phases described

| Version family | Capability theme |
|---|---|
| 2.0.x | Per-account service isolation, port/credential setup, installer and migration foundation. |
| 2.1.x | WHM dashboard, account controls, backups, recovery and hardening. |
| 2.2.x | cPanel monitoring, presets, backup/restore, configuration and health handling. |
| 2.3.x | Package/reseller groundwork, branding, history, application detection, setup checks and targeted session recovery. |
| 2.4.x | Redis/Valkey abstraction, OS-aware fresh installation choice, WHM backend selection, diagnostics and recovery. |
| 2.5.x | Package enforcement, reseller quotas, exposure levels, provider hooks and explicit migration. |
| 2.6.x | Abuse reporting, AUTH protections, commercial licensing automation, dashboard performance, branding and stability fixes. |

## Forward-looking themes

The reference groups its next observational/debugging work around richer graphs, slow-log visibility, security summaries and health scoring. Later themes include worker/auto-healing infrastructure, cross-server import/export, configuration profiles, a REST API/webhooks, external Redis connections, cluster/Sentinel and support for another panel.

## ORM planning rule

ORM's roadmap is separately maintained under [`project/README.md`](../project/README.md). Ideas from the reference are inputs to discovery, not automatic scope. Release claims in ORM must be backed by code and environment evidence.
