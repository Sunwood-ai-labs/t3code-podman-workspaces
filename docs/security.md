# Security

[Architecture](architecture.md) · [English README](../README.md) · [日本語 README](../README.ja.md)

The initial deployment assumes **trusted internal users** and a trusted host administrator. T3 Code hosts agents that can execute arbitrary commands and code, including code influenced by repositories, prompts, dependencies, and tool output. Treat a workspace as a code execution environment with access to its credentials, not merely a web application.

All containers share the host's Linux kernel. Rootless Podman and separate networks are useful boundaries, but do not provide a VM boundary or a guarantee against malicious tenants. No integration test results are available yet; this document records the configured design and distinguishes additional recommendations.

## Threat model

Consider stolen pairing links/sessions, compromised clients or agents, malicious project contents, credential exfiltration, unintended access to internal services, cross-user access, resource exhaustion, and compromise of Caddy or the shared host/runtime. A hostile multi-tenant service or exposure to untrusted public users is outside the assumed deployment model.

The host deployment account can administer the rootless containers and persistent data. Caddy can reach all workspace networks and holds CA private state. Compromise of either is a shared risk; per-user container names are not separate administrative security domains.

## Current configuration and intended controls

These are the initial implementation's specified controls, **not verified isolation or end-to-end test results**:

| Control | Boundary / limitation |
| --- | --- |
| Rootless Podman + Quadlet | Run under the deployment account; kernel/runtime compromise and access available to that account remain risks. |
| One container and network per user | Separate direct network membership. Caddy joins all networks; outbound access and access through Caddy require separate controls. |
| No user container host ports | Workspace port `3773` is reached through Caddy. Caddy alone publishes host `8080` and `8443`. |
| Caddy `tls internal` | Encrypt browser-to-Caddy traffic at `https://<user>.t3.example.internal:8443`. Client root trust is managed by administrators; upstream HTTP is not encrypted by this setting. |
| Required T3 one-time pairing/session | Establish and require an application session for each workspace. Treat pairing links and session tokens as secrets. |
| Access logs to Caddy stdout/journald | Intended HTTP access record, not a complete audit of agent commands or filesystem changes. |
| Versioned T3 image and resource settings | T3 npm `0.0.45`, image `localhost/t3code-workspace:0.0.45`; limits require host and rendered-unit validation. A tag is not an immutable digest. |

SSO is **optional**, through Caddy `forward_auth` with oauth2-proxy or Authelia, and is not configured by this document. T3 pairing/session remains required even with SSO. A generic SSO gate does not authorize a user for a specific hostname: configure and test identity-to-workspace rules and coverage of the application's HTTP/WebSocket routes before relying on them. See [Caddy's forward_auth documentation](https://caddyserver.com/docs/caddyfile/directives/forward_auth).

## Not protected by this design

This design does not claim to prevent kernel/runtime escapes, malicious administrator access, agent misuse of granted tools/credentials, outbound exfiltration, access to reachable internal services, denial of service across shared host resources, or compromise propagated through shared Caddy. Separate Podman networks alone are not an egress policy. There is no described high availability or tamper-resistant audit pipeline.

## Additional recommendations — not implemented here

- **Network reachability:** restrict ingress to approved internal clients/VPNs. Enforce egress allowlists for required providers, package sources, and Git remotes; block unnecessary host, internal service, and metadata endpoint access. Verify IPv4/IPv6 and actual rootless network behavior. Do not assume an internal DNS name enforces access control.
- **Runtime hardening:** retain supported seccomp/LSM protections, minimize mounts and privileges, and avoid exposing container-engine sockets or sensitive host directories to agents. Evaluate gVisor or Kata for a stronger execution boundary, including Podman/rootless compatibility and workload tests; neither is enabled by this design.
- **Resource controls:** validate configured memory/CPU/PID limits and monitor disk usage. Add appropriate storage and workload quotas; shared-host exhaustion is still possible.
- **SSO authorization:** if adding SSO, restrict each identity to its intended workspace, protect auth headers from spoofing, and test route/session behavior. Maintain T3 pairing as the application layer.

## Secrets and agent contracts

Give each workspace its own narrowly scoped provider API keys and Git credentials. Avoid shared administrator tokens, cross-user credential mounts, and host SSH-agent/container socket exposure. Store secrets using an approved mechanism outside source control; `config.env` and generated configuration are not a secret vault. Persistent files, environment inspection, and backups can expose credentials to the agent or deployment administrator.

Define an explicit agent contract: permitted repositories, tools, commands, network destinations, data, spending limits, and approval requirements. Treat repository instructions and external tool output as untrusted input. This deployment does not enforce such a contract by itself; prompts alone are not a security boundary. Establish credential rotation, pairing/session revocation, and offboarding procedures using the pinned T3 version's supported mechanisms, and verify them before use.

## Certificates, updates, and recovery

Protect `t3code-caddy-data`, which contains CA certificates and private keys, and `t3code-caddy-config`. Administrators distribute **only `root.crt`** over an authenticated channel and verify its fingerprint; never distribute `root.key` or the whole data volume. Limit backup access and encrypt sensitive backups. CA compromise requires key replacement and redistribution of trust.

Keep the T3 npm version and image tag aligned. `docker.io/library/caddy:2` follows a moving major-version tag; recommend pinning an approved exact version or digest for reproducible deployments. Updates should be deliberate:

1. Review T3, Caddy, base image, and host/runtime changes; choose approved versions.
2. Back up user data and sensitive Caddy state according to [image](image.md) and [operations](operations.md).
3. Build the candidate image and validate render/install, TLS trust, routing, pairing/session, agent execution, persistence, network behavior, and limits in a disposable staging environment.
4. Apply the approved shared settings, render/install, and restart affected services following operations guidance. Confirm browser access for each user and retain a compatible rollback plan.

This is a recommended update procedure, not a report of completed testing. T3's `0.0.x` maturity makes compatibility and recovery validation especially necessary.

## Logs and audit

The Caddy site template configures access logs to stdout, and the Quadlet template selects the journald log driver. Confirm the rendered configuration and runtime collection; see the [log directive](https://caddyserver.com/docs/caddyfile/directives/log). Set retention, access restrictions, and any central collection separately.

The site template removes Authorization/Cookie request headers and selected token-related query parameters from access logs. This is partial filtering, not proof that every pairing URL, token, API key, or sensitive query string is hidden. Verify redaction in the actual access/application logs. HTTP access records do not show every command an agent executes: add an appropriate application/agent audit trail if policy requires it, and define incident response and credential revocation procedures. Complete redaction and these additional audit measures have not been validated here.
