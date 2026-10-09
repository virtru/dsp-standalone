# Local Virtru DSP Development Stack

This project runs the Virtru Data Security Platform (DSP), Keycloak, and their
PostgreSQL databases as a local Docker Compose stack. It is intended for SDK
development, policy experiments, and integration testing without Kubernetes.

> **Local development only:** The stack uses published ports, self-signed
> certificates, and well-known sample credentials. Do not expose it to a
> network or use it for production data.

## Release compatibility

Download a Virtru DSP bundle from
[secure.virtru.com/download](https://secure.virtru.com/download). The setup
script accepts a `.tar.gz` archive or an unpacked directory. It reads the bundle
release from a name such as `virtru-dsp-bundle-2.0.6.7` and detects the platform
version from the bundled `dsp version` command. It then loads and verifies that
exact platform image tag in the local registry and passes the image to Docker
Compose. An older image already in the registry is not selected automatically.

The legacy `virtru-dsp-bundle/` directory has no release in its name, so the
script uses `2.0.6.7` as its display label. Its platform image tag still comes
from the bundled CLI. A differently named bundle also gets the fallback display
label and a warning; its detected platform version remains authoritative.

### Platform status

| Host | Status |
|---|---|
| Ubuntu 24.04 LTS, amd64 | Validated with the complete automated test suite |
| macOS, Intel or Apple Silicon | Configured; not revalidated in this release update |
| RHEL 8, amd64 | Experimental; not revalidated in this release update |
| Ubuntu 24.04 or RHEL 8, arm64 | Experimental; runs the amd64 DSP image through emulation |
| Windows or other Linux distributions | Not supported by these scripts |

The DSP container image is `linux/amd64` on every host. Emulation on arm64 can
increase startup time substantially.

## Quick start

### 1. Prepare the host

You need:

- a Virtru DSP bundle `.tar.gz` download or unpacked directory;
- internet access for system packages, public Go modules, and container images;
- enough disk space for the approximately 5 GB bundle, its unpacked copy, and
  the local container images; and
- `sudo` access for local certificates, `/etc/hosts`, and Linux package
  installation.

Start a Docker-compatible runtime before running setup.

On macOS, [OrbStack](https://orbstack.dev) is recommended because this stack
uses host networking. If you use Docker Desktop, enable host networking. On
Apple Silicon, also enable Rosetta for amd64 emulation.

### 2. Run setup

From this directory, set `BUNDLE` to your downloaded archive or unpacked bundle
directory. The release in this example is illustrative; use the path you received:

```bash
cd dsp-standalone
export BUNDLE=/path/to/virtru-dsp-bundle-2.0.6.7.tar.gz
./setup_and_validate.sh --bundle "$BUNDLE"
```

On Apple M4 with Colima, if Keycloak exits with SIGILL/code 134, try the
[OpenTDF SVE workaround](https://opentdf.io/getting-started) for that run:

```bash
JAVA_TOOL_OPTIONS='-XX:+IgnoreUnrecognizedVMOptions -XX:UseSVE=0' \
  ./setup_and_validate.sh --bundle "$BUNDLE"
```

The macOS Compose override passes this setting to Keycloak's JVM and Java
health check. Leave it unset when Keycloak starts normally.

Existing stacks started with `KC_DB_VENDOR` stored Keycloak data in the
container's H2 database. The corrected `KC_DB` setting starts with the
PostgreSQL database and setup provisions a new sample realm there. Manually
created users or realm changes in H2 are not migrated; back up that container's
`/opt/keycloak/data/h2` directory before upgrading if you need them.

The command installs or verifies prerequisites, safely unpacks the bundle under
`.generated/`, creates local keys, loads the detected DSP image, starts the
stack, provisions the sample federal policy, and runs infrastructure, tagging,
and Go SDK tests.

### What the host needs

| Phase | Requirements |
|---|---|
| Run an already prepared stack | A running Docker engine with Compose and host networking; the built DSP image, Keycloak and PostgreSQL images, generated certificates/keys, config files, and `local-dsp.virtru.com` resolving to `127.0.0.1`. |
| First setup or rebuild | The DSP bundle, Docker Buildx, a reachable local registry on port 5000, `curl`, `jq`, `mkcert`, `openssl`, and `cosign`. macOS also uses `shasum`, `tar`, and `gzip` from the system to unpack the archive; Linux uses `python3` to prepare its DSP config. |
| Default SDK validation | Go and access to its module dependencies. Go is not used by the running containers. |

The `mkcert` and `cosign` executables generate the certificate and signing keys;
the containers use the resulting files. The registry serves the bundle image
during setup and builds. Homebrew is only needed to install a missing host tool.
Node.js, nvm, wget, git, and make are not required by this stack on macOS.

If you omit `--bundle`, setup uses `./virtru-dsp-bundle` when that directory
exists. Otherwise it prompts for a bundle path in an interactive terminal. In
non-interactive runs, pass `--bundle` explicitly.

The unpacked bundle is reused on later runs. Setup keys the cache by the
archive's SHA-256 checksum, so replacing an archive under the same filename
creates a new unpacked directory instead of reusing stale files.

### 3. Complete first-time Linux setup

On a first Ubuntu or RHEL run, the prerequisite script adds your account to the
`docker` group. That membership cannot affect the shell that launched setup,
so the first run stops with instructions. Activate the group and rerun:

```bash
newgrp docker

./setup_and_validate.sh \
  --skip-prereqs \
  --bundle "$BUNDLE"
```

Logging out and back in is an alternative to `newgrp docker`.

### Expected result

Setup finishes with a pass/fail summary. A successful default run verifies:

- DSP and Keycloak health and provisioning;
- the exact DSP runtime version;
- federal attributes and both PostgreSQL databases;
- SDK encryption, permitted decryption, and expected access denial; and
- the federal tagging workflow.

Run `docker compose ps -a` to inspect the stack. The database, Keycloak, and
DSP services should be healthy. Provisioning services are one-shot containers
and should exit with status 0.

## Setup and validation options

```bash
./setup_and_validate.sh --help
```

| Option | Behavior |
|---|---|
| `--bundle PATH` | Use a bundle archive or unpacked directory; detect its platform version |
| `--skip-prereqs` | Skip installation but still verify required tools |
| `--no-build` | Reuse previously built Compose images |
| `--validate-only` | Validate an already-running stack without starting it |
| `--sdk-only` | Run only the Go SDK programs against a running stack |
| `--add-namespace company` | Provision and validate the optional `company.com` sample |

Common repeat commands:

```bash
# Full validation against a running stack
./setup_and_validate.sh \
  --validate-only \
  --bundle "$BUNDLE"

# Go SDK tests only; a bundle is not required in this mode
./setup_and_validate.sh --sdk-only

# Restart with cached images, then run all validation
./setup_and_validate.sh \
  --skip-prereqs \
  --no-build \
  --bundle "$BUNDLE"
```

Go dependency/build caches and runtime artifacts such as `alex_test.tdf` are
kept under the ignored `.generated/` directory. The SDK module itself is
committed at the project root so repository CI and dependency tooling can
inspect it directly.

## Optional company policy

The `company.com` example adds department, sensitivity, and classification
attributes and four department users. For a new stack:

```bash
./setup_and_validate.sh \
  --bundle "$BUNDLE" \
  --add-namespace company
```

To add it to an already-running stack and run its validation:

```bash
./setup_and_validate.sh \
  --validate-only \
  --bundle "$BUNDLE" \
  --add-namespace company
```

See [company-policy/README.md](company-policy/README.md) for the policy model,
sample users, and advanced policy construction script.

## Operating the stack

Run commands from `dsp-standalone/`.

### Start an initialized stack

After the automated setup has created keys, staged configuration, loaded the
DSP image, and built the local images:

```bash
KEYCLOAK_REALM_EXISTS=true docker compose up -d
```

On macOS, include the checked-in health-check override when starting directly:

```bash
KEYCLOAK_REALM_EXISTS=true docker compose \
  -f docker-compose.yaml \
  -f docker-compose.mac.yml \
  up -d
```

These direct Compose commands assume the existing database containers still
contain the realm and policy from setup. The environment flag prevents the
one-shot provisioner from rerunning against existing users. After `down`, run
the full setup command to provision the new database containers.

### Stop without reinitializing

```bash
docker compose stop
```

The PostgreSQL services use anonymous volumes. `docker compose down` removes
their containers, and a later `up` creates new database volumes. To remove the
stack and reinitialize it on the next setup run:

```bash
docker compose down
```

To remove the stack and delete its current anonymous database volumes:

```bash
docker compose down -v
```

> `down -v` permanently removes locally provisioned users, policies, and
> database data. Keys and generated files on the host are not removed.

### Logs and status

```bash
docker compose ps -a
docker compose logs -f
docker compose logs -f dsp
docker compose logs -f keycloak
docker compose logs dsp-keycloak-provisioning
docker compose logs dsp-provision-federal-policy
```

### Rebuild explicitly

For a manual rebuild, use the version reported by the selected bundle's CLI.
Set `BUNDLE_DIR` to the unpacked path in setup's "Using DSP bundle" log line:

```bash
BUNDLE_DIR=/path/from/setup-log
DSP_VERSION=$("$BUNDLE_DIR/dsp" version | awk '$1 == "Version:" { print $2; exit }')
export DSP_IMAGE="localhost:5000/virtru/data-security-platform:v${DSP_VERSION#v}"
docker compose build --build-arg "DSP_IMAGE=$DSP_IMAGE"
KEYCLOAK_REALM_EXISTS=true docker compose up -d
```

On macOS, pass both Compose files to the build and start commands:

```bash
docker compose -f docker-compose.yaml -f docker-compose.mac.yml \
  build --build-arg "DSP_IMAGE=$DSP_IMAGE"
KEYCLOAK_REALM_EXISTS=true docker compose \
  -f docker-compose.yaml -f docker-compose.mac.yml up -d
```

After a manual start, run `./setup_and_validate.sh --validate-only --bundle "$BUNDLE_DIR"`
to check the complete federal sample policy and the rest of the stack.

## Services and endpoints

| Service | Host endpoint or port | Purpose |
|---|---|---|
| DSP | [https://local-dsp.virtru.com:8080](https://local-dsp.virtru.com:8080) | KAS, policy, authorization, and entity resolution |
| DSP health | [https://local-dsp.virtru.com:8080/healthz](https://local-dsp.virtru.com:8080/healthz) | Runtime readiness |
| Keycloak | [https://local-dsp.virtru.com:18443/auth](https://local-dsp.virtru.com:18443/auth) | OIDC realm and admin console |
| Keycloak management | `9000` | Container health check on Linux |
| DSP PostgreSQL | `35433` | Local DSP database |
| Keycloak PostgreSQL | `25434` | Local Keycloak database |
| Docker registry | `5000` | Local DSP image registry |

The startup dependency order is:

```text
keycloak-db -> keycloak -> dsp-keycloak-provisioning
dsp-db -------------------------------------------> dsp
dsp -> dsp-provision-federal-policy
```

Allow several minutes on the first run, especially when amd64 emulation is in
use.

## Test instructions

### Full automated validation

```bash
./setup_and_validate.sh \
  --validate-only \
  --bundle "$BUNDLE"
```

The command checks service health, provisioning, the runtime version, policy
objects, database connectivity, SDK behavior, and tagging behavior. It exits
nonzero if a required check fails.

### SDK validation

The SDK suite uses the public
[OpenTDF platform SDK](https://github.com/opentdf/platform) and does not require
a private Go module configuration.

| Command package | Expected behavior |
|---|---|
| `cmd/toy-sdk` | Alex encrypts and decrypts a Top Secret TDF |
| `cmd/bob-test-alex-file` | Bob decrypts it through matching TS and FVEY entitlements |
| `cmd/alice-test-alex-file` | KAS denies Alice because she has only Secret clearance |
| `cmd/company-namespace-validation` | With `--add-namespace company`, Engineering is allowed and HR is denied for engineering-tagged data |

```bash
./setup_and_validate.sh --sdk-only
```

An access-denied result for Alice is a successful security test.

The commands can also be compiled without a running DSP stack:

```bash
go mod download
go mod verify
go build ./...
```

To exercise them manually against a running stack, start with `toy-sdk` so the
other commands can read its generated TDF:

```bash
go run ./cmd/toy-sdk
go run ./cmd/bob-test-alex-file
go run ./cmd/alice-test-alex-file

# After provisioning the optional company namespace
go run ./cmd/company-namespace-validation
```

### Go quality checks

The committed `go.mod` lets dependency and security tooling inspect the SDK
examples directly. Before submitting changes, run module download and checksum
verification, `govulncheck`, golangci-lint, race-enabled Go tests, formatting
validation, and a tidy-module drift check. These checks compile the command
packages without starting Docker or contacting DSP; the live allow/deny
behavior remains part of `setup_and_validate.sh`.

### Tagging validation

```bash
# Default federal workflow
./test_tagging.sh --namespace federal

# After provisioning the optional company namespace
./test_tagging.sh --namespace federal --namespace company
```

### Manual smoke checks

```bash
# DSP
curl -fks https://local-dsp.virtru.com:8080/healthz | jq .

# Keycloak realm
curl -fks \
  https://local-dsp.virtru.com:18443/auth/realms/opentdf \
  | jq -r .realm

# Containers, including completed one-shot provisioners
docker compose ps -a
```

Expected health is HTTP 200 with a serving status, the realm name is
`opentdf`, and both provisioners have exit code 0.

## Sample credentials

| Service or user | Username or client ID | Password or secret |
|---|---|---|
| Keycloak administrator | `admin` | `changeme` |
| DSP PostgreSQL | `postgres` | `changeme` |
| Keycloak PostgreSQL | `postgres` | `changeme` |
| DSP service client | `opentdf` | `secret` |
| SDK service client | `opentdf-sdk` | `secret` |
| Alice, Secret/USA | `aaa@secret.usa` | `testuser123` |
| Alex, Top Secret/USA | `aaa@topsecret.usa` | `testuser123` |
| Bob, Top Secret/GBR | `bbb@topsecret.gbr` | `testuser123` |
| Jane, Confidential/FRA | `int@classified.fra` | `testuser123` |
| James, Unclassified/MEX | `user@unclassified.mex` | `testuser123` |

These credentials are intentionally insecure and are only for the isolated
local stack.

## Customizing users and policy

### Access model

The sample implements attribute-based access control:

```text
Keycloak user claims
  -> subject condition sets
  -> DSP subject mappings
  -> attribute values applied to a TDF
  -> KAS allow or deny decision
```

The generated federal policy uses the `demo.com` namespace:

| Attribute | Rule | Meaning |
|---|---|---|
| `classification` | `HIERARCHY` | Higher clearance includes lower levels |
| `needtoknow` | `ALL_OF` | A user must hold every applied compartment |
| `relto` | `ANY_OF` | One matching country or coalition is sufficient |

### Add a sample user

Users are defined in [sample.keycloak.yaml](sample.keycloak.yaml). The
interactive helper validates the required fields and writes a correctly shaped
entry:

```bash
python3 add_user.py
```

The helper updates `sample.keycloak.yaml` for the next clean setup. The bundled
Keycloak importer creates the whole sample realm and must not be rerun against
an existing realm. To add the user to a running stack without resetting it,
create the user in the [Keycloak admin console](https://local-dsp.virtru.com:18443/auth/admin)
with the password, attributes, realm role, and optional group shown by the
helper. To apply the edited YAML through the importer, back up any local data,
run `docker compose down -v`, then run the full setup again.

The important user claims are `clearance`, `needToKnow`, and `nationality`.
They must match the subject condition sets in the generated
`sample.federal_policy.yaml`.

To inspect a user through the Keycloak admin API, obtain an administrator token
from the `master` realm. Replace `secret-aus-ops` with the username you added:

```bash
ADMIN_TOKEN=$(curl -fks \
  -d 'grant_type=password' \
  -d 'client_id=admin-cli' \
  -d 'username=admin' \
  -d 'password=changeme' \
  https://local-dsp.virtru.com:18443/auth/realms/master/protocol/openid-connect/token \
  | jq -r .access_token)

curl -fks \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  'https://local-dsp.virtru.com:18443/auth/admin/realms/opentdf/users?username=secret-aus-ops' \
  | jq '.[0] | {username, email, attributes}'
```

The Keycloak admin console is available at
[https://local-dsp.virtru.com:18443/auth/admin](https://local-dsp.virtru.com:18443/auth/admin).
See the
[Keycloak Server Administration Guide](https://www.keycloak.org/docs/latest/server_admin/)
for UI operations.

### Change the federal policy

`sample.federal_policy.yaml` is copied from the selected bundle during setup and
is gitignored because it is release-generated input. It contains attribute
definitions, values, condition sets, and subject mappings.

The sample policy provisioner creates objects; it is not a migration engine.
For repeatable local policy edits, reset the local databases and provision from
a clean stack:

```bash
# Destructive: removes both local database volumes
docker compose down -v

./setup_and_validate.sh \
  --skip-prereqs \
  --bundle "$BUNDLE"
```

For non-destructive updates, use the `tructl policy` update commands supplied
by the same bundle rather than rerunning the create-only sample provisioner.
The exact policy validator also checks counts from bundle 2.0.6.7; review
those counts when changing `DEFAULT_DSP_BUNDLE_RELEASE` and update them if the
sample layout changes.

### Configuration reference

| File | Purpose |
|---|---|
| [docker-compose.yaml](docker-compose.yaml) | Services, networking, health checks, and a fallback image for manual Compose commands |
| [dsp.yaml](dsp.yaml) | DSP runtime configuration |
| [sample.keycloak.yaml](sample.keycloak.yaml) | Default realm, clients, users, and user claims |
| `sample.federal_policy.yaml` | Generated local copy of the bundle's federal policy |
| [sample.company_keycloak.yaml](sample.company_keycloak.yaml) | Optional company users |
| [sample.company_policy.yaml](sample.company_policy.yaml) | Optional company policy |
| [config/company.tagging-pdp-workflows.yaml](config/company.tagging-pdp-workflows.yaml) | Additive company tagging overlay |

## Troubleshooting

### Docker is not accessible on Linux

```bash
newgrp docker
docker info
```

If that does not work, log out and back in. Then rerun setup with
`--skip-prereqs`.

### Bundle or image version mismatch

Use the unpacked path in setup's "Using DSP bundle" log line to inspect its CLI:

```bash
BUNDLE_DIR=/path/from/setup-log
"$BUNDLE_DIR/dsp" version
```

Setup expects the local registry image tag to match that reported version with
a leading `v`. It rejects failed CLI commands, missing or invalid versions,
and a bundle that does not supply the matching image. Docker Compose's
`v2.7.15` fallback applies only to manual Compose commands that do not set
`DSP_IMAGE`; the setup script exports the detected image before invoking Compose.

### Port 5000 returns 403 on macOS

macOS AirPlay Receiver commonly occupies port 5000. Disable **AirPlay
Receiver** under **System Settings > General > AirDrop & Handoff**, then rerun
setup.

### A service does not become healthy

```bash
docker compose ps -a
docker compose logs --tail=200 keycloak
docker compose logs --tail=200 dsp
docker compose logs --tail=200 dsp-keycloak-provisioning
docker compose logs --tail=200 dsp-provision-federal-policy
```

Also confirm that `local-dsp.virtru.com` resolves to `127.0.0.1` and that
all files under `dsp-keys/` exist.

### Port conflicts

The stack uses host networking for DSP and Keycloak. Stop the conflicting
process when possible. Changing only a Compose `ports:` entry is not enough
for host-networked services.

- Changing Keycloak database port `25434` requires updating its published
  Compose port and `KC_DB_URL_PORT`.
- Changing DSP database port `35433` requires updating its published Compose
  port, `DSP_DB_PORT`, and the database port in [dsp.yaml](dsp.yaml).
- Changing DSP `8080` or Keycloak `18443` also requires coordinated updates
  to DSP configuration, provisioning commands, certificates/endpoints, tests,
  and SDK examples.

### Reset a broken local stack

```bash
# Destructive: deletes local database volumes
docker compose down -v

./setup_and_validate.sh \
  --skip-prereqs \
  --bundle "$BUNDLE"
```

Do not delete the downloaded customer bundle; it is needed to rebuild the
local registry and restage release configuration.
