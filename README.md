# DSP-Standalone Local Deployment

Runs the Virtru Data Security Platform (DSP) as a self-contained Docker Compose stack — no Kubernetes or bulk data ingestion. Intended to support local SDK development and testing.

> **Local dev only.** This setup uses default usernames and credentials and should not be used for any purpose beyond local integration development and testing.

## Getting Started

For the full interactive guide with architecture diagrams, collapsible sections, and search, open:

```
docs/dsp-standalone-guide.html
```

in your browser.

## Quick Start

```bash
./setup_and_validate.sh
```

This single command handles prerequisites, key generation, Docker registry setup, stack startup, and validation. See the [guide](docs/dsp-standalone-guide.html) for flags (`--skip-prereqs`, `--no-build`, `--validate-only`, `--sdk-only`).

## What's Included

| Service | Image | Port(s) | Role |
|---|---|---|---|
| `keycloak-db` | postgres:16 | 25434 | Keycloak's Postgres database |
| `keycloak` | keycloak/keycloak:25.0 | 18443 (HTTPS), 8888 (HTTP health) | Identity Provider (OIDC) |
| `dsp-keycloak-provisioning` | built from dev.dsp.Dockerfile | — | One-shot: provisions realm, clients, and users |
| `dsp-db` | postgres:16 | 35433 | DSP's Postgres database |
| `dsp` | built from dev.dsp.Dockerfile | 8080 | DSP services (KAS, policy, authz, entity resolution) |
| `dsp-provision-federal-policy` | built from dev.dsp.Dockerfile | — | One-shot: loads the federal attribute policy |

## Supported Platforms

| Platform | Status |
|---|---|
| macOS (Intel + Apple Silicon) | Supported |
| Ubuntu 24.04 LTS (amd64 + arm64) | Experimental |
| Red Hat Enterprise Linux 8 (amd64 + arm64) | Experimental |
| Windows | Not supported |

**OrbStack** is the recommended Docker runtime on macOS.

## Documentation

The full guide (`docs/dsp-standalone-guide.html`) covers:

- **Architecture** — service diagram, startup dependency chain, networking model
- **Validation** — automated and manual health checks
- **SDK Examples** — three Go programs testing TDF encrypt/decrypt flows
- **Users & Credentials** — test users, entitlements, service credentials
- **Operations** — managing users, attributes, and troubleshooting
- **Access Control (ABAC)** — attribute definitions, condition sets, subject mappings
- **Configuration Files** — dsp.yaml, keycloak, docker-compose details
- **Manual Setup** — step-by-step instructions for manual installation
