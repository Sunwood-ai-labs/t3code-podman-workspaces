# Architecture

[English README](../README.md) · [日本語 README](../README.ja.md) · [Security](security.md)

This document describes the single-host design. What has been exercised is listed in the [integration test record](integration-test.md). Optional extensions below are not part of the default deployment.

## Components

| Component | Responsibility |
| --- | --- |
| Linux host / rootless Podman 5.x | Run containers under the deployment account; containers share the host kernel. |
| systemd Quadlet | Describe and manage the rootless container/network lifecycle through user services. |
| `users.conf` | List workspace identities; defaults are `user1`, `user2`, `user3`. These are workspace names, not necessarily separate Linux login accounts. |
| `config.env` | Shared domain, image, port, and resource settings read by the scripts. |
| T3 workspace image | T3 Code npm `0.0.45`, tagged `localhost/t3code-workspace:0.0.45`, running `t3 serve` on container port `3773`. |
| `t3code-<user>` | One agent workspace and its T3 pairing/session state per user. No published host port. |
| `t3code-caddy` | `docker.io/library/caddy:2`; TLS termination and hostname routing, publishing host HTTP `8080` and HTTPS `8443`. |

The build → render → install → pair lifecycle uses `scripts/build-image.sh`, `scripts/render.sh`, `scripts/install.sh`, and `scripts/pair.sh <user>`. See the README for commands and [operations](operations.md) for service lifecycle details.

## Request flow

1. Internal wildcard DNS `*.t3.example.internal` resolves to the host. Wildcard DNS does not itself provision workspace routes.
2. The browser connects to `https://<user>.t3.example.internal:8443`. Caddy terminates TLS using the default `tls internal` CA; client trust must be provisioned separately.
3. If configured, Caddy checks the optional SSO layer through `forward_auth` with oauth2-proxy or Authelia.
4. Caddy selects the configured hostname route and proxies to `t3code-<user>:3773` on that user's network.
5. T3 Code requires one-time pairing to establish a session and validates the session for subsequent application access. Users must pair with their own workspace even when SSO is enabled.
6. Agents operate inside that workspace and may execute arbitrary commands and code. HTTPS terminates at Caddy; the described upstream hop uses HTTP inside the container network.

## Networks and authentication boundaries

Each workspace joins its corresponding `t3code-<user>` network. User containers do not share a workspace network with one another, and each network sets `isolate=strict` so that Podman does not route between them. Caddy joins **every** workspace network so it can reach all upstreams; it is a shared, privileged point within this topology, despite running rootless. Only Caddy exposes host ports.

This separates direct container-network membership. It does not guarantee isolation from other users reached through public Caddy routes, host services, outbound networks, or a kernel/runtime exploit. Rootless operation does not create a VM boundary, and network separation does not enforce per-user application authorization. See [security](security.md).

There are two distinct authentication layers: required T3 pairing/session authentication and optional frontend SSO. Adding an SSO login gate does not automatically map an SSO identity to an authorized workspace. Identity-to-hostname authorization must be designed and tested separately.

## Data and configuration

| Location | Contents / handling |
| --- | --- |
| Repository `users.conf`, `config.env` | Deployment inputs; keep credentials out of this public repository. |
| Rendered Caddy/Quadlet configuration | Derived routes, networks, services, and limits; installation paths and restart procedure are specified by [operations](operations.md). |
| Named volume `t3code-caddy-data` | Caddy persistent PKI state, including the CA certificate and private keys. Preserve and restrict access; distribute only the public `root.crt`. |
| Named volume `t3code-caddy-config` | Caddy persistent configuration state; do not treat it as a public artifact. |
| Named volumes `t3code-<user>-home`, `-workspace`, `-data` | Mounted at `/home/dev` (agent sign-ins and tool configuration), `/workspace` (project files) and `/data` (T3 Code state under `/data/t3`, including paired sessions). They survive restarts, reinstalls and `uninstall.sh` unless `--purge-volumes` is given. |
| Host `~/.config/t3code/<user>.env` | Per-user environment variables such as API keys, mode `600`, passed to the container at start. |
| Caddy stdout / journald | Intended destination for access logs. Retention, access controls, and audit collection are operator responsibilities. |

Backups must cover both user data and sensitive Caddy state; losing or replacing the CA can require redistributing client trust.

## Capacity and limits

This is a single-host deployment with one container per user and one shared Caddy instance. The host, rootless deployment account, storage, and Caddy are common failure domains. There is no described high availability, cross-host scheduling, or automatic failover.

The shared settings currently specify per-workspace limits of `4g` memory, `2` CPUs, and `2048` PIDs. They were confirmed on the running containers in the integration test; their effect under real agent load was not measured. Agent workloads, disk growth, outbound traffic, and provider quotas still need capacity planning.

T3 Code is on the `0.0.x` release line. CLI, pairing, persistence, and proxy behavior may change; validate a pinned upgrade before rolling it out. The T3 image is version-tagged; Caddy's `:2` is a moving major-version tag, not an immutable pin.

## Optional or future work

SSO integration, explicit per-hostname SSO authorization, egress filtering, stronger workload runtimes such as gVisor/Kata, centralized auditing, and multi-host availability are separate extensions. They are not implemented or validated guarantees of the current design.
