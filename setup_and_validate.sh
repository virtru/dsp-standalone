#!/usr/bin/env bash
# =============================================================================
# setup_and_validate.sh
#
# Runs all prerequisites, starts the DSP-only Docker Compose stack, and
# executes the full validation suite from the README.
#
# Configured for macOS, Ubuntu 24.04, and RHEL 8 (amd64 + arm64 hosts).
# See README.md for the current validation status and emulation requirements.
#
# Usage:
#   ./setup_and_validate.sh                              # full run: prereqs + infra checks + SDK validation
#   ./setup_and_validate.sh --bundle /path/to/bundle     # use a supported bundle outside ./virtru-dsp-bundle
#   ./setup_and_validate.sh --add-namespace company      # also provision the sample company namespace + users
#   ./setup_and_validate.sh --skip-prereqs               # skip tool installs, go straight to keys/stack
#   ./setup_and_validate.sh --no-build                   # start stack using cached images (no --build)
#   ./setup_and_validate.sh --validate-only              # infra checks + SDK validation (no setup)
#   ./setup_and_validate.sh --sdk-only                   # run Go SDK tests only (skip setup + infra checks)
# =============================================================================

set -euo pipefail

# Public DSP release supported by this local deployment. The downloadable
# bundle and the platform container use separate version schemes.
readonly DSP_BUNDLE_RELEASE="2.0.6.6"
readonly DSP_PLATFORM_IMAGE_TAG="v2.7.14"
readonly INVOCATION_DIR="$PWD"

usage() {
  cat <<EOF
Usage: ./setup_and_validate.sh [options]

Set up and validate the local Virtru DSP development stack.

Options:
  --bundle PATH             DSP $DSP_BUNDLE_RELEASE bundle directory or .tar.gz archive
  --add-namespace company   Provision and validate the optional company.com sample
  --skip-prereqs            Skip prerequisite installation; verify tools only
  --no-build                Reuse previously built Compose images
  --validate-only           Validate an already-running stack without starting it
  --sdk-only                Run only the Go SDK validation programs
  -h, --help                Show this help

Examples:
  ./setup_and_validate.sh --bundle /path/to/virtru-dsp-bundle-$DSP_BUNDLE_RELEASE.tar.gz
  ./setup_and_validate.sh --skip-prereqs --bundle /path/to/virtru-dsp-bundle-$DSP_BUNDLE_RELEASE.tar.gz
  ./setup_and_validate.sh --validate-only --bundle .generated/virtru-dsp-bundle-$DSP_BUNDLE_RELEASE
EOF
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
SKIP_PREREQS=false
VALIDATE_ONLY=false
SDK_VALIDATION=true
SDK_ONLY=false
NO_BUILD=false
BUNDLE_PATH=""
ADD_NAMESPACES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-prereqs)    SKIP_PREREQS=true; shift ;;
    --validate-only)   VALIDATE_ONLY=true; shift ;;
    --sdk-validation)  SDK_VALIDATION=true; shift ;;
    --sdk-only)        SDK_ONLY=true; SDK_VALIDATION=true; VALIDATE_ONLY=true; shift ;;
    --no-build)        NO_BUILD=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    --bundle)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "FATAL: --bundle requires a path to the DSP $DSP_BUNDLE_RELEASE bundle directory or .tar.gz archive" >&2
        exit 1
      fi
      BUNDLE_PATH="$2"
      shift 2
      ;;
    --bundle=*)
      BUNDLE_PATH="${1#*=}"
      if [[ -z "$BUNDLE_PATH" ]]; then
        echo "FATAL: --bundle requires a path to the DSP $DSP_BUNDLE_RELEASE bundle directory or .tar.gz archive" >&2
        exit 1
      fi
      shift
      ;;
    --add-namespace)
      if [[ $# -lt 2 ]]; then
        echo "FATAL: --add-namespace requires a value (supported: company)" >&2
        exit 1
      fi
      ADD_NAMESPACES+=("$2")
      shift 2
      ;;
    --add-namespace=*)
      ADD_NAMESPACES+=("${1#*=}")
      shift
      ;;
    *)
      echo "FATAL: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log_section() { echo; echo -e "${BOLD}${BLUE}==> $*${NC}"; }
log_info()    { echo -e "    ${BLUE}·${NC} $*"; }
log_ok()      { echo -e "    ${GREEN}✓${NC} $*"; }
log_warn()    { echo -e "    ${YELLOW}⚠${NC}  $*"; }
log_fail()    { echo -e "    ${RED}✗${NC} $*"; }
die()         { echo -e "\n${RED}FATAL:${NC} $*\n" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then
  die "Do not run setup_and_validate.sh with sudo or as root. Run it as your normal user; the prerequisite scripts invoke sudo only for system-level changes."
fi

PASS=0; FAIL=0
TAGGING_PDP_WORKFLOW_CHANGED=false
check_pass() { log_ok "$1"; ((PASS++)) || true; }
check_fail() { log_fail "$1"; ((FAIL++)) || true; }

contains_item() {
  local needle="$1"
  shift || true
  local item=""
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

normalize_requested_namespaces() {
  local normalized=()
  local ns=""
  if [[ ${#ADD_NAMESPACES[@]} -eq 0 ]]; then
    return 0
  fi
  for ns in "${ADD_NAMESPACES[@]}"; do
    case "$ns" in
      company)
        if [[ ${#normalized[@]} -eq 0 ]] || ! contains_item "$ns" "${normalized[@]}"; then
          normalized+=("$ns")
        fi
        ;;
      "")
        die "Namespace value cannot be empty"
        ;;
      *)
        die "Unsupported namespace '$ns'. Supported values: company"
        ;;
    esac
  done
  if [[ ${#normalized[@]} -gt 0 ]]; then
    ADD_NAMESPACES=("${normalized[@]}")
  else
    ADD_NAMESPACES=()
  fi
}

namespace_requested() {
  [[ ${#ADD_NAMESPACES[@]} -gt 0 ]] || return 1
  contains_item "$1" "${ADD_NAMESPACES[@]}"
}

normalize_requested_namespaces

if [[ "$SDK_ONLY" == true && ${#ADD_NAMESPACES[@]} -gt 0 ]]; then
  die "--sdk-only cannot be combined with --add-namespace because SDK-only mode skips bundle staging and provisioning."
fi

# ---------------------------------------------------------------------------
# OS / architecture detection
# ---------------------------------------------------------------------------
log_section "Detecting environment"

OS_RAW=$(uname -s)
ARCH_RAW=$(uname -m)

case "$OS_RAW" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux"  ;;
  *)      die "Unsupported OS: $OS_RAW" ;;
esac

case "$ARCH_RAW" in
  x86_64)        ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)             die "Unsupported architecture: $ARCH_RAW" ;;
esac

# HOST_ARCH  — native CPU arch; used for installing tools (Go, mkcert, DSP CLI)
# CONTAINER_ARCH — always amd64; DSP Docker images are linux/amd64-only
HOST_ARCH="$ARCH"
CONTAINER_ARCH="amd64"

# Linux distro detection — used to select prereqs script and distro-specific commands
DISTRO_ID=""
DISTRO_ID_LIKE=""
IS_RHEL=false
if [[ "$OS" == "linux" ]]; then
  DISTRO_ID=$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  DISTRO_ID_LIKE=$(grep -E '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
  if [[ "$DISTRO_ID" == "rhel" || "$DISTRO_ID" == "centos" || "$DISTRO_ID" == "rocky" || "$DISTRO_ID" == "almalinux" || "$DISTRO_ID_LIKE" == *"rhel"* ]]; then
    IS_RHEL=true
  fi
fi

log_ok "OS: $OS_RAW  |  Host arch: ${OS}/${HOST_ARCH}  |  Container arch: linux/${CONTAINER_ARCH}"
if [[ "$OS" == "linux" ]]; then
  log_ok "Linux distro: ${DISTRO_ID}  |  RHEL-family: ${IS_RHEL}"
fi
if [[ ${#ADD_NAMESPACES[@]} -gt 0 ]]; then
  log_ok "Optional namespaces to add: ${ADD_NAMESPACES[*]}"
else
  log_ok "Optional namespaces to add: none"
fi

# RHEL-specific environment checks
if [[ "$IS_RHEL" == true ]]; then

  # SELinux check — enforcing mode blocks Docker bind mounts without :z label
  if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Unknown")
    if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
      log_warn "SELinux is Enforcing. Docker bind mounts require the :z volume label or"
      log_warn "SELinux may block container access to dsp-keys/ and config files."
      log_warn "The docker-compose.yaml in this repo includes :z labels for RHEL compatibility."
    else
      log_ok "SELinux status: ${SELINUX_STATUS}"
    fi
  fi

  # firewalld check — blocks loopback traffic between host-networked and bridge-networked
  # containers (e.g. keycloak → keycloak-db). Auto-fix by adding docker0 to trusted zone.
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    log_warn "firewalld is active — checking Docker interface trust..."
    DOCKER0_ZONE=$(sudo firewall-cmd --get-zone-of-interface=docker0 2>/dev/null || echo "")
    if [[ "$DOCKER0_ZONE" == "trusted" ]]; then
      log_ok "firewalld: docker0 is already in the trusted zone"
    else
      log_info "Adding docker0 to firewalld trusted zone (required for Keycloak → DB connectivity)..."
      sudo firewall-cmd --permanent --zone=trusted --add-interface=docker0
      sudo firewall-cmd --reload
      log_ok "firewalld: docker0 added to trusted zone"
    fi
  else
    log_ok "firewalld is not active"
  fi

  # iptables/nftables check — CentOS 8 defaults to nftables; Docker requires iptables.
  # If nftables is the active backend, Docker's rules are silently ignored and containers
  # cannot communicate, causing Keycloak to fail to start.
  if command -v iptables &>/dev/null; then
    IPTABLES_VERSION=$(iptables --version 2>/dev/null || echo "")
    if echo "$IPTABLES_VERSION" | grep -q "nf_tables"; then
      log_warn "iptables is using the nftables backend — Docker requires iptables-legacy."
      log_warn "Switching to iptables-legacy..."
      if command -v update-alternatives &>/dev/null; then
        if sudo update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null \
          && sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null; then
          log_ok "Switched to iptables-legacy — restarting Docker daemon..."
          if sudo systemctl restart docker; then
            log_ok "Docker restarted with iptables-legacy backend"
          else
            log_warn "Could not restart Docker automatically. Run manually:\n  sudo systemctl restart docker"
          fi
        else
          log_warn "Could not switch iptables backend automatically. Run manually:\n  sudo update-alternatives --set iptables /usr/sbin/iptables-legacy\n  sudo systemctl restart docker"
        fi
      else
        log_warn "update-alternatives not found. Switch manually:\n  sudo update-alternatives --set iptables /usr/sbin/iptables-legacy\n  sudo systemctl restart docker"
      fi
    else
      log_ok "iptables backend: legacy (compatible with Docker)"
    fi
  fi

fi

# Warn Docker Desktop users on Apple Silicon
if [[ "$OS" == "darwin" && "$ARCH" == "arm64" ]]; then
  if docker info 2>/dev/null | grep -q "Docker Desktop"; then
    log_warn "Docker Desktop detected on Apple Silicon."
    log_warn "OrbStack (https://orbstack.dev) is recommended for this stack — it provides"
    log_warn "native host networking and built-in Rosetta for linux/amd64 images."
    log_warn "If staying with Docker Desktop, enable Rosetta:"
    log_warn "  Settings → General → Use Rosetta for x86/amd64 emulation on Apple Silicon"
  else
    log_ok "Docker runtime: $(docker info 2>/dev/null | grep 'Operating System' | awk -F': ' '{print $2}' || echo 'unknown')"
  fi
fi

# Work from the dsp-standalone directory regardless of the caller's directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
GENERATED_DIR="$SCRIPT_DIR/.generated"
GENERATED_TAGGING_PDP_WORKFLOW="$GENERATED_DIR/tagging-pdp-workflows.yaml"
log_ok "Working directory: $SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Compose file selection — OS-aware healthcheck override
# macOS uses the Java-based HTTP check on port 8888 (reliable in start-dev).
# Linux (Ubuntu + RHEL/CentOS) uses the Keycloak 25+ management port (9000).
# ---------------------------------------------------------------------------
if [[ "$OS" == "darwin" ]]; then
  export COMPOSE_FILE="docker-compose.yaml:docker-compose.mac.yml"
  log_ok "Compose: using macOS override (docker-compose.mac.yml)"
else
  export COMPOSE_FILE="docker-compose.yaml"
fi

# ---------------------------------------------------------------------------
# Helper: validate required tools are present after prereqs run
# ---------------------------------------------------------------------------
REQUIRED_TOOLS=(docker jq mkcert cosign openssl curl)

validate_tools() {
  local missing=()
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
      log_ok "$tool → $(command -v "$tool")"
    else
      log_fail "$tool not found"
      missing+=("$tool")
    fi
  done

  # Fail hard on missing binaries first
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo
    log_fail "Missing tools: ${missing[*]}"
    die "Fix the above then re-run with --skip-prereqs to skip tool installation."
  fi

  # Docker daemon check — warn only, do not die
  # On Linux the docker group change requires a new login session; the binary
  # may be installed but the daemon unreachable until the user re-logs in.
  if command -v docker &>/dev/null; then
    if docker info &>/dev/null 2>&1; then
      log_ok "Docker daemon is running"
    else
      log_warn "Docker binary found but daemon is not running or not accessible."
      if [[ "$OS" == "darwin" ]]; then
        log_warn "Start OrbStack or Docker Desktop, then re-run."
      else
        log_warn "If you were just added to the docker group, run: newgrp docker"
        log_warn "Or log out and back in, then re-run with --skip-prereqs."
        log_warn "Continuing — Docker steps may fail if the daemon is unreachable."
      fi
    fi
  fi
}

find_tructl() {
  if [[ -n "${TRUCTL:-}" && -x "${TRUCTL}" ]]; then
    printf '%s\n' "$TRUCTL"
    return 0
  fi

  local candidates=()
  local candidate=""
  if [[ -n "${BUNDLE_DIR:-}" ]]; then
    candidates+=(
      "$BUNDLE_DIR/tructl"
      "$BUNDLE_DIR"/tools/dsp/*/tructl
    )
    for candidate in "${candidates[@]}"; do
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done

    # A selected bundle has already passed the release-version check. Do not
    # fall back to tructl from another, potentially older bundle.
    return 1
  fi

  candidates=(
    "$SCRIPT_DIR/virtru-dsp-bundle/tructl"
    "$SCRIPT_DIR/virtru-dsp-bundle"/tools/dsp/*/tructl
    "$SCRIPT_DIR"/virtru-dsp-bundle-*/tructl
    "$SCRIPT_DIR"/virtru-dsp-bundle-*/tools/dsp/*/tructl
  )
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$SCRIPT_DIR" -type f -name tructl 2>/dev/null | sort)

  return 1
}

get_service_account_token() {
  curl -fksSo - --max-time 10 \
    -d "grant_type=client_credentials&client_id=opentdf&client_secret=secret" \
    https://local-dsp.virtru.com:18443/auth/realms/opentdf/protocol/openid-connect/token \
    2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true
}

get_keycloak_admin_token() {
  curl -fksSo - --max-time 10 \
    -d "grant_type=password&client_id=admin-cli&username=admin&password=changeme" \
    https://local-dsp.virtru.com:18443/auth/realms/master/protocol/openid-connect/token \
    2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true
}

list_policy_attribute_pairs() {
  local token="$1"
  curl -ksSo - --max-time 10 -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "connect-protocol-version: 1" \
    -d '{"pagination":{}}' \
    "https://local-dsp.virtru.com:8080/policy.attributes.AttributesService/ListAttributes" \
    2>/dev/null | jq -r '.attributes[]? | "\(.namespace.name)/\(.name)"' 2>/dev/null | sort -u
}

company_policy_is_present() {
  local token="$1"
  local attrs=""
  local expected=""

  attrs="$(list_policy_attribute_pairs "$token")"
  for expected in company.com/classification company.com/department company.com/sensitivity; do
    if ! grep -qx "$expected" <<<"$attrs"; then
      return 1
    fi
  done
  return 0
}

company_users_are_present() {
  local admin_token="$1"
  local users=""
  local expected=""

  users="$(curl -fksSo - --max-time 10 \
    -H "Authorization: Bearer $admin_token" \
    "https://local-dsp.virtru.com:18443/auth/admin/realms/opentdf/users?max=200" \
    2>/dev/null | jq -r '.[].username // empty' 2>/dev/null | sort -u)"

  for expected in engineering-company-user hr-company-user accounting-company-user sales-company-user; do
    if ! grep -qx "$expected" <<<"$users"; then
      return 1
    fi
  done
  return 0
}

provision_company_namespace() {
  local tructl_bin=""
  local kc_output=""
  local policy_output=""
  local token=""
  local admin_token=""

  log_section "Provisioning optional namespace: company"

  [[ -f "$SCRIPT_DIR/sample.company_keycloak.yaml" ]] || die "Missing file: $SCRIPT_DIR/sample.company_keycloak.yaml"
  [[ -f "$SCRIPT_DIR/sample.company_policy.yaml" ]] || die "Missing file: $SCRIPT_DIR/sample.company_policy.yaml"

  tructl_bin="$(find_tructl)" || die "Could not find tructl in an unpacked DSP bundle. Re-run setup with a local bundle available."
  log_ok "Using tructl: $tructl_bin"

  kc_output="$("$tructl_bin" provision keycloak-from-config \
    -f "$SCRIPT_DIR/sample.company_keycloak.yaml" \
    -e https://local-dsp.virtru.com:18443/auth 2>&1)" || {
      echo "$kc_output" | while IFS= read -r line; do log_fail "  $line"; done
      die "Failed to provision company Keycloak users"
    }
  log_ok "Company Keycloak users provisioned"

  policy_output="$("$tructl_bin" \
    --host https://local-dsp.virtru.com:8080 \
    --tls-no-verify \
    --with-client-creds '{"clientId":"opentdf","clientSecret":"secret"}' \
    provision policy \
    -n company.com \
    -f "$SCRIPT_DIR/sample.company_policy.yaml" 2>&1)" || {
      if echo "$policy_output" | grep -q "namespace company.com already exists: bad namespace"; then
        log_warn "Company namespace already exists in DSP — validating existing policy objects"
      else
        echo "$policy_output" | while IFS= read -r line; do log_fail "  $line"; done
        die "Failed to provision company DSP policy"
      fi
    }
  if [[ -n "$policy_output" ]] && ! echo "$policy_output" | grep -q "namespace company.com already exists: bad namespace"; then
    log_ok "Company DSP policy provisioned"
  fi

  token="$(get_service_account_token)"
  [[ -n "$token" ]] || die "Could not obtain DSP service-account token after company provisioning"
  company_policy_is_present "$token" || die "Company namespace attributes were not found after provisioning"
  log_ok "Company namespace attributes are present in DSP"

  admin_token="$(get_keycloak_admin_token)"
  [[ -n "$admin_token" ]] || die "Could not obtain Keycloak admin token after company provisioning"
  company_users_are_present "$admin_token" || die "Company Keycloak users were not found after provisioning"
  log_ok "Company Keycloak users are present"
}

resolve_tagging_pdp_workflow_source() {
  local bundle_dir="${1:-}"
  local default_bundle_dir="$SCRIPT_DIR/virtru-dsp-bundle"
  local candidate=""
  local prompt_path=""

  if [[ -n "$bundle_dir" && -f "$bundle_dir/kubernetes/tagging-pdp-workflows.yaml" ]]; then
    candidate="$bundle_dir/kubernetes/tagging-pdp-workflows.yaml"
    log_info "Using tagging PDP workflow from bundle: $candidate"
    TAGGING_PDP_WORKFLOW_SOURCE="$candidate"
    return 0
  fi

  if [[ -f "$default_bundle_dir/kubernetes/tagging-pdp-workflows.yaml" ]]; then
    candidate="$default_bundle_dir/kubernetes/tagging-pdp-workflows.yaml"
    log_info "Using tagging PDP workflow from unpacked bundle: $candidate"
    TAGGING_PDP_WORKFLOW_SOURCE="$candidate"
    return 0
  fi

  echo
  log_warn "tagging-pdp-workflows.yaml was not found in the bundle at ./kubernetes/tagging-pdp-workflows.yaml."
  while true; do
    read -rp "  Enter the path to your tagging PDP workflow YAML: " prompt_path
    prompt_path="${prompt_path/#\~/$HOME}"
    if [[ -z "$prompt_path" ]]; then
      echo "  Path cannot be empty."
      continue
    fi
    if [[ ! -f "$prompt_path" ]]; then
      echo "  File not found: $prompt_path"
      continue
    fi
    TAGGING_PDP_WORKFLOW_SOURCE="$prompt_path"
    return 0
  done
}

extract_tagging_pdp_workflow() {
  local source_path="$1"
  local output_path="$2"

  if grep -q '^taggingpdpWorkflows:$' "$source_path" && grep -q '^  config\.yaml:$' "$source_path"; then
    awk '
      /^  config\.yaml:$/ { emit=1; next }
      emit {
        if ($0 ~ /^    /) {
          sub(/^    /, "")
          print
        } else if ($0 ~ /^$/) {
          print ""
        } else {
          exit
        }
      }
    ' "$source_path" > "$output_path"
  else
    cp "$source_path" "$output_path"
  fi
}

extract_tagging_overlay_section() {
  local overlay_path="$1"
  local section_name="$2"
  local output_path="$3"

  awk -v section="$section_name" '
    $0 == section ":" { emit=1; next }
    emit {
      if ($0 ~ /^[A-Za-z0-9_-][^:]*:([[:space:]].*)?$/) {
        exit
      }
      print
    }
  ' "$overlay_path" > "$output_path"
}

merge_tagging_pdp_workflow() {
  local base_path="$1"
  local overlay_path="$2"
  local output_path="$3"
  local base_raw="$GENERATED_DIR/tagging-pdp-base.yaml"
  local overlay_resource="$GENERATED_DIR/tagging-pdp-overlay-resourceMappingSets.yaml"
  local overlay_rules="$GENERATED_DIR/tagging-pdp-overlay-tagExtractionRules.yaml"

  extract_tagging_pdp_workflow "$base_path" "$base_raw"
  extract_tagging_overlay_section "$overlay_path" "resourceMappingSets" "$overlay_resource"
  extract_tagging_overlay_section "$overlay_path" "tagExtractionRules" "$overlay_rules"

  awk -v resource_file="$overlay_resource" -v rules_file="$overlay_rules" '
    function printfile(path, line) {
      while ((getline line < path) > 0) {
        print line
      }
      close(path)
    }
    {
      if ($0 == "resourceMappingSets:") {
        if (current == "rules" && !rules_done) {
          printfile(rules_file)
          rules_done = 1
        }
        current = "resource"
      } else if ($0 == "tagExtractionRules:") {
        if (current == "resource" && !resource_done) {
          printfile(resource_file)
          resource_done = 1
        }
        current = "rules"
      } else if ($0 ~ /^[A-Za-z0-9_-][^:]*:([[:space:]].*)?$/) {
        if (current == "resource" && !resource_done) {
          printfile(resource_file)
          resource_done = 1
        } else if (current == "rules" && !rules_done) {
          printfile(rules_file)
          rules_done = 1
        }
        current = ""
      }

      print
    }
    END {
      if (current == "resource" && !resource_done) {
        printfile(resource_file)
      } else if (current == "rules" && !rules_done) {
        printfile(rules_file)
      }
    }
  ' "$base_raw" > "$output_path"
}

stage_tagging_pdp_workflow() {
  local source_path="$1"
  local company_overlay_path="$SCRIPT_DIR/config/company.tagging-pdp-workflows.yaml"
  local staged_candidate="$GENERATED_DIR/tagging-pdp-workflows.staged.yaml"

  mkdir -p "$GENERATED_DIR"
  if namespace_requested company && [[ -f "$company_overlay_path" ]]; then
    merge_tagging_pdp_workflow "$source_path" "$company_overlay_path" "$staged_candidate"
    log_info "Merged federal tagging workflow with company tagging overlay"
  else
    extract_tagging_pdp_workflow "$source_path" "$staged_candidate"
    if grep -q '^taggingpdpWorkflows:$' "$source_path" && grep -q '^  config\.yaml:$' "$source_path"; then
      log_info "Extracted inner tagging PDP workflow from bundle wrapper format"
    fi
  fi

  if [[ -f "$GENERATED_TAGGING_PDP_WORKFLOW" ]] && cmp -s "$staged_candidate" "$GENERATED_TAGGING_PDP_WORKFLOW"; then
    TAGGING_PDP_WORKFLOW_CHANGED=false
    rm -f "$staged_candidate"
    log_info "Tagging PDP workflow unchanged"
  else
    mv "$staged_candidate" "$GENERATED_TAGGING_PDP_WORKFLOW"
    TAGGING_PDP_WORKFLOW_CHANGED=true
  fi
  log_ok "Staged tagging PDP workflow: $GENERATED_TAGGING_PDP_WORKFLOW"
}

ensure_bundle_directory_ready() {
  local bundle_dir="$1"
  local dsp_tar=""
  local bundle_platform_version=""
  local normalized_bundle_platform_version=""
  local normalized_expected_platform_version="${DSP_PLATFORM_IMAGE_TAG#v}"

  if [[ ! -x "$bundle_dir/dsp" ]]; then
    case "$OS" in
      darwin) dsp_tar=$(find "$bundle_dir/tools/dsp" -maxdepth 1 -type f -name "data-security-platform_*_darwin_${HOST_ARCH}.tar.gz" | head -1) ;;
      linux)  dsp_tar=$(find "$bundle_dir/tools/dsp" -maxdepth 1 -type f -name "data-security-platform_*_linux_${HOST_ARCH}.tar.gz" | head -1) ;;
    esac

    if [[ -z "$dsp_tar" ]]; then
      log_fail "'dsp' binary not found in $bundle_dir"
      log_fail "Expected either $bundle_dir/dsp or a matching archive under tools/dsp/."
      return 1
    fi

    log_info "Unpacking DSP CLI from bundle contents: ${dsp_tar#"$bundle_dir"/}"
    tar -xvf "$dsp_tar" -C "$bundle_dir" >/dev/null
    chmod +x "$bundle_dir/dsp"
  fi

  bundle_platform_version=$("$bundle_dir/dsp" version 2>&1 \
    | awk '$1 == "Version:" { print $2; exit }')
  normalized_bundle_platform_version="${bundle_platform_version#v}"
  if [[ "$normalized_bundle_platform_version" != "$normalized_expected_platform_version" ]]; then
    log_fail "DSP bundle CLI version mismatch in $bundle_dir"
    log_fail "Expected $DSP_PLATFORM_IMAGE_TAG from bundle $DSP_BUNDLE_RELEASE; got ${bundle_platform_version:-unknown}."
    return 1
  fi

  log_ok "DSP $bundle_platform_version CLI is ready in $bundle_dir"
}

registry_has_dsp_tag() {
  local tags_json="$1"
  local expected_tag="$2"

  jq -e --arg expected_tag "$expected_tag" \
    '(.tags // []) | index($expected_tag) != null' \
    <<<"$tags_json" >/dev/null 2>&1
}

unpack_bundle_archive() {
  local bundle_tar="$1"
  local bundle_name bundle_dir unsafe_member

  bundle_name="$(basename "$bundle_tar")"
  bundle_name="${bundle_name%.tar.gz}"
  bundle_dir="$GENERATED_DIR/$bundle_name"

  if [[ -d "$bundle_dir" ]] && ensure_bundle_directory_ready "$bundle_dir"; then
    log_ok "Reusing unpacked DSP bundle: $bundle_dir"
    UNPACKED_BUNDLE_DIR="$bundle_dir"
    return 0
  fi

  if ! gzip -t "$bundle_tar"; then
    log_fail "Bundle is not a valid gzip archive: $bundle_tar"
    return 1
  fi

  unsafe_member="$(tar -tzf "$bundle_tar" | awk '
    ($0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/) && first == "" { first=$0 }
    END { if (first != "") print first }
  ')"
  if [[ -n "$unsafe_member" ]]; then
    log_fail "Bundle contains an unsafe archive path: $unsafe_member"
    return 1
  fi

  mkdir -p "$bundle_dir"
  log_info "Unpacking Virtru DSP bundle archive: $bundle_tar"
  tar -xvf "$bundle_tar" -C "$bundle_dir" >/dev/null

  ensure_bundle_directory_ready "$bundle_dir" || return 1
  UNPACKED_BUNDLE_DIR="$bundle_dir"
}

prepare_bundle_input() {
  local bundle_input="$1"

  if [[ -f "$bundle_input" ]]; then
    if [[ "$bundle_input" != *.tar.gz ]]; then
      die "Expected --bundle to identify a Virtru DSP bundle .tar.gz archive or an unpacked bundle directory: $bundle_input"
    fi
    unpack_bundle_archive "$bundle_input" \
      || die "Could not prepare DSP bundle $DSP_BUNDLE_RELEASE from $bundle_input"
    BUNDLE_DIR="$UNPACKED_BUNDLE_DIR"
  elif [[ -d "$bundle_input" ]]; then
    ensure_bundle_directory_ready "$bundle_input" \
      || die "Could not prepare DSP bundle $DSP_BUNDLE_RELEASE from $bundle_input"
    BUNDLE_DIR="$bundle_input"
  else
    die "DSP bundle path not found: $bundle_input"
  fi

  log_ok "Using DSP bundle $DSP_BUNDLE_RELEASE from $BUNDLE_DIR"
}

if [[ -n "$BUNDLE_PATH" ]]; then
  BUNDLE_PATH="${BUNDLE_PATH/#\~/$HOME}"
  if [[ "$BUNDLE_PATH" != /* ]]; then
    BUNDLE_PATH="$INVOCATION_DIR/$BUNDLE_PATH"
  fi
  prepare_bundle_input "$BUNDLE_PATH"
fi

# ---------------------------------------------------------------------------
# Prerequisites — delegate to OS-specific script
# ---------------------------------------------------------------------------
if [[ "$VALIDATE_ONLY" == false ]]; then

  if [[ "$SKIP_PREREQS" == false ]]; then

    log_section "Running prerequisites script"

    case "$OS" in
      darwin) PREREQS_SCRIPT="$SCRIPT_DIR/mac_prereqs.sh" ;;
      linux)
        if [[ "$IS_RHEL" == true ]]; then
          PREREQS_SCRIPT="$SCRIPT_DIR/rhel_prereqs.sh"
        else
          PREREQS_SCRIPT="$SCRIPT_DIR/ubuntu_prereqs.sh"
        fi
        ;;
    esac

    if [[ ! -f "$PREREQS_SCRIPT" ]]; then
      die "Prerequisites script not found: $PREREQS_SCRIPT\nExpected it alongside setup_and_validate.sh."
    fi

    if [[ ! -x "$PREREQS_SCRIPT" ]]; then
      log_info "Making $PREREQS_SCRIPT executable..."
      chmod +x "$PREREQS_SCRIPT"
    fi

    log_info "Executing: $PREREQS_SCRIPT"
    echo

    PREREQS_EXIT=0
    bash "$PREREQS_SCRIPT" || PREREQS_EXIT=$?

    echo
    if [[ $PREREQS_EXIT -ne 0 ]]; then
      log_warn "Prerequisites script exited with code $PREREQS_EXIT — some tools may not have installed correctly."
      log_warn "Continuing to container setup. Re-run with --skip-prereqs if tools are already installed."
    else
      log_ok "Prerequisites script completed successfully (exit 0)"
    fi

    log_section "Validating installed tools"
    validate_tools

    # On Linux, Docker group membership requires a new login session to take
    # effect. The prereqs script runs in a subshell, so the group change never
    # propagates back here. Exit early with a clear message rather than
    # proceeding through key generation only to die at the registry step.
    if [[ "$OS" == "linux" ]] && ! docker info &>/dev/null 2>&1; then
      echo
      die "Docker was installed but is not accessible in this session.\n\nThe docker group change requires a new login session to take effect.\n\nNext steps:\n  1. Run:  newgrp docker\n     (opens a new shell with the docker group active)\n  2. Then re-run:  ./setup_and_validate.sh --skip-prereqs\n\nOr log out and back in, then re-run with --skip-prereqs."
    fi

  else

    log_section "Skipping prerequisites (--skip-prereqs)"
    log_info "Checking that required tools are already available..."
    validate_tools

  fi

  # --- federal policy sample ------------------------------------------------
  log_section "Sample federal policy"

  FEDERAL_SRC="${BUNDLE_DIR:-$SCRIPT_DIR/virtru-dsp-bundle}/samples/defaults/federal.yaml"
  FEDERAL_DST="$SCRIPT_DIR/sample.federal_policy.yaml"

  if [[ -f "$FEDERAL_DST" ]]; then
    log_ok "sample.federal_policy.yaml already exists — skipping"
  elif [[ -f "$FEDERAL_SRC" ]]; then
    cp "$FEDERAL_SRC" "$FEDERAL_DST"
    log_ok "Copied $FEDERAL_SRC → $FEDERAL_DST"
  else
    log_warn "Bundle policy file not found: $FEDERAL_SRC"
    log_warn "sample.federal_policy.yaml will need to be provided manually before starting the stack."
  fi

  # --- /etc/hosts -----------------------------------------------------------
  log_section "/etc/hosts"

  if grep -q "local-dsp\.virtru\.com" /etc/hosts; then
    log_ok "local-dsp.virtru.com already in /etc/hosts"
  else
    log_info "Adding 127.0.0.1 local-dsp.virtru.com to /etc/hosts (requires sudo)..."
    echo "127.0.0.1    local-dsp.virtru.com" | sudo tee -a /etc/hosts > /dev/null
    log_ok "Entry added"
  fi

  # --- mkcert trust store ---------------------------------------------------
  log_section "TLS trust store (mkcert)"

  if [[ "$OS" == "linux" ]]; then
    # On Linux mkcert -install must run as the REGULAR USER so the CA is
    # created in the user's CAROOT (~/.local/share/mkcert/) and NSS databases
    # in the user's home are updated. Running as sudo creates the CA under
    # /root and the two halves never match.
    # After that, copy the CA into the system store separately with sudo.

    # Check mkcert binary is the correct arch — reinstall if not executable
    if command -v mkcert &>/dev/null; then
      if ! mkcert --version &>/dev/null 2>&1; then
        log_warn "mkcert binary cannot execute (wrong arch?) — reinstalling for linux/${HOST_ARCH}..."
        MKCERT_VERSION=$(curl -fsSL https://api.github.com/repos/FiloSottile/mkcert/releases/latest \
          | grep tag_name | cut -d'"' -f4)
        wget -q -P /tmp "https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-${HOST_ARCH}"
        sudo rm -f /usr/local/bin/mkcert
        sudo mv "/tmp/mkcert-${MKCERT_VERSION}-linux-${HOST_ARCH}" /usr/local/bin/mkcert
        sudo chmod +x /usr/local/bin/mkcert
        log_ok "mkcert reinstalled: $(mkcert --version)"
      fi
    fi

    # On headless Ubuntu (no browser installed) mkcert -install prints:
    # "ERROR: no Firefox and/or Chrome/Chromium security databases found"
    # and exits non-zero. For this stack we only need system trust (curl + Go TLS),
    # not browser trust. TRUST_STORES=system skips NSS database lookup entirely.
    log_info "Running mkcert -install (system trust store only, linux/${HOST_ARCH})..."
    if TRUST_STORES=system mkcert -install 2>&1; then
      log_ok "mkcert CA installed (system trust store)"
    else
      log_warn "mkcert -install reported warnings — continuing."
    fi

    log_info "Copying mkcert CA to system trust store..."
    MKCERT_CAROOT=$(mkcert -CAROOT 2>/dev/null || echo "")
    if [[ -f "${MKCERT_CAROOT}/rootCA.pem" ]]; then
      if [[ "$IS_RHEL" == true ]]; then
        # RHEL/CentOS: trust anchors live in /etc/pki/ca-trust/source/anchors/
        MKCERT_SYSTEM_CA_PATH="/etc/pki/ca-trust/source/anchors/mkcert-rootCA.pem"
        if [[ -f "$MKCERT_SYSTEM_CA_PATH" ]] \
          && cmp -s "${MKCERT_CAROOT}/rootCA.pem" "$MKCERT_SYSTEM_CA_PATH"; then
          log_ok "mkcert CA already matches the system trust store (RHEL)"
        else
          sudo cp "${MKCERT_CAROOT}/rootCA.pem" "$MKCERT_SYSTEM_CA_PATH"
          sudo update-ca-trust extract && log_ok "mkcert CA added to system trust store (RHEL)"
        fi
      else
        # Debian/Ubuntu: trust anchors live in /usr/local/share/ca-certificates/
        MKCERT_SYSTEM_CA_PATH="/usr/local/share/ca-certificates/mkcert-rootCA.crt"
        if [[ -f "$MKCERT_SYSTEM_CA_PATH" ]] \
          && cmp -s "${MKCERT_CAROOT}/rootCA.pem" "$MKCERT_SYSTEM_CA_PATH"; then
          log_ok "mkcert CA already matches the system trust store (Ubuntu)"
        else
          sudo cp "${MKCERT_CAROOT}/rootCA.pem" "$MKCERT_SYSTEM_CA_PATH"
          sudo update-ca-certificates && log_ok "mkcert CA added to system trust store (Ubuntu)"
        fi
      fi
    else
      log_warn "Could not find mkcert rootCA.pem at ${MKCERT_CAROOT} — system trust store not updated."
    fi
  else
    if mkcert -install 2>/dev/null; then
      log_ok "mkcert CA installed"
    else
      log_warn "mkcert -install failed (may need sudo or NSS tools). Continuing."
    fi
  fi

  # --- dsp-keys/ ------------------------------------------------------------
  log_section "Generating dsp-keys/"

  mkdir -p dsp-keys/policyimportexport

  # TLS cert
  if [[ -f dsp-keys/local-dsp.virtru.com.pem && -f dsp-keys/local-dsp.virtru.com.key.pem ]]; then
    log_ok "TLS cert already exists — skipping"
  else
    log_info "Generating TLS certificate..."
    mkcert \
      -cert-file dsp-keys/local-dsp.virtru.com.pem \
      -key-file  dsp-keys/local-dsp.virtru.com.key.pem \
      local-dsp.virtru.com "*.local-dsp.virtru.com" localhost
    log_ok "TLS certificate generated"
  fi
  # KAS RSA key pair
  if [[ -f dsp-keys/kas-private.pem && -f dsp-keys/kas-cert.pem ]]; then
    log_ok "KAS RSA keys already exist — skipping"
  else
    log_info "Generating KAS RSA key pair..."
    openssl req -x509 -nodes -newkey RSA:2048 -subj "/CN=kas" \
      -keyout dsp-keys/kas-private.pem -out dsp-keys/kas-cert.pem -days 365 2>/dev/null
    log_ok "KAS RSA key pair generated"
  fi

  # KAS EC key pair
  if [[ -f dsp-keys/kas-ec-private.pem && -f dsp-keys/kas-ec-cert.pem ]]; then
    log_ok "KAS EC keys already exist — skipping"
  else
    log_info "Generating KAS EC key pair..."
    openssl ecparam -name prime256v1 > dsp-keys/ecparams.tmp
    openssl req -x509 -nodes -newkey ec:dsp-keys/ecparams.tmp -subj "/CN=kas" \
      -keyout dsp-keys/kas-ec-private.pem -out dsp-keys/kas-ec-cert.pem -days 365 2>/dev/null
    rm dsp-keys/ecparams.tmp
    log_ok "KAS EC key pair generated"
  fi

  # Check cosign binary is the correct arch — reinstall if not executable (Linux only)
  if [[ "$OSTYPE" == "linux"* ]] && command -v cosign &>/dev/null; then
    if ! cosign version &>/dev/null 2>&1; then
      log_warn "cosign binary cannot execute (wrong arch?) — reinstalling for linux/${HOST_ARCH}..."
      COSIGN_VERSION=$(curl -fsSL https://api.github.com/repos/sigstore/cosign/releases/latest | grep tag_name | cut -d'"' -f4)
      curl -fsSLo /tmp/cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${HOST_ARCH}"
      sudo rm -f /usr/local/bin/cosign
      sudo mv /tmp/cosign /usr/local/bin/cosign
      sudo chmod +x /usr/local/bin/cosign
      log_ok "cosign reinstalled for linux/${HOST_ARCH}: $(cosign version 2>&1 | head -1)"
    fi
  fi

  # cosign key pair
  if [[ -f dsp-keys/policyimportexport/cosign.key && -f dsp-keys/policyimportexport/cosign.pub ]]; then
    log_ok "cosign keys already exist — skipping"
  else
    log_info "Generating policy import/export signing keys..."
    COSIGN_PASSWORD=changeme cosign generate-key-pair \
      --output-key-prefix dsp-keys/policyimportexport/cosign 2>/dev/null
    printf '%s' 'changeme' > dsp-keys/policyimportexport/cosign.pass
    log_ok "cosign key pair generated"
  fi

  # encrypted-search.key
  if [[ -f dsp-keys/encrypted-search.key ]]; then
    log_ok "encrypted-search.key already exists — skipping"
  else
    log_info "Writing encrypted-search.key..."
    printf '%s' '49e9a28af998c2678e6651ad4e60a2dbba2f3d284f58b224b3382919c1de7d55' \
      > dsp-keys/encrypted-search.key
    log_ok "encrypted-search.key written"
  fi

  # On Linux, mkcert and openssl generate private keys with 0600 (owner-read only).
  # Containers run as non-root users and cannot read root-owned 0600 files via bind mount.
  # Set all keys in dsp-keys/ to 0644 so container users can read them.
  # Done after all keys are generated so every file exists before chmod runs.
  # Safe for local dev only — do not use in production.
  if [[ "$OS" == "linux" ]]; then
    chmod 0644 \
      dsp-keys/local-dsp.virtru.com.key.pem \
      dsp-keys/kas-private.pem \
      dsp-keys/kas-ec-private.pem \
      dsp-keys/policyimportexport/cosign.key
    log_ok "dsp-keys/ private key permissions set to 0644 (required for container read access on Linux)"
  fi

  # --- Docker DNS check (Linux only) ----------------------------------------
  # Must run BEFORE starting the registry or loading the DSP image.
  # Ubuntu uses systemd-resolved (127.0.0.53) which Docker containers cannot
  # reach. Fixing DNS requires restarting the Docker daemon, which wipes any
  # in-memory registry data — so we fix DNS first, then start the registry.
  if [[ "$OS" == "linux" ]]; then
    log_section "Docker DNS check (Linux)"
    DAEMON_JSON="/etc/docker/daemon.json"
    DNS_OK=false
    if docker run --rm --network bridge alpine:latest nslookup dl-cdn.alpinelinux.org &>/dev/null 2>&1; then
      DNS_OK=true
    fi
    if [[ "$DNS_OK" == false ]]; then
      log_warn "Docker containers cannot resolve DNS — configuring daemon DNS (8.8.8.8, 1.1.1.1)..."
      if [[ -f "$DAEMON_JSON" ]]; then
        sudo python3 -c "
import json, sys
with open('$DAEMON_JSON') as f:
    d = json.load(f)
d['dns'] = ['8.8.8.8', '1.1.1.1']
with open('$DAEMON_JSON', 'w') as f:
    json.dump(d, f, indent=2)
print('Updated $DAEMON_JSON')
"
      else
        echo '{"dns": ["8.8.8.8", "1.1.1.1"]}' | sudo tee "$DAEMON_JSON" > /dev/null
        log_ok "Created $DAEMON_JSON with DNS servers"
      fi
      log_info "Restarting Docker daemon to apply DNS settings..."
      sudo systemctl restart docker
      sleep 3
      log_ok "Docker daemon restarted — DNS set to 8.8.8.8, 1.1.1.1"
    else
      log_ok "Docker container DNS is working"
    fi
  fi

  # --- Local Docker registry ------------------------------------------------
  log_section "Local Docker registry (port 5000)"

  # Verify Docker is accessible before any docker commands
  if ! docker info &>/dev/null 2>&1; then
    die "Docker daemon is not accessible.\nOn Linux, run: newgrp docker  (or log out and back in)\nThen re-run with: --skip-prereqs"
  fi

  # On macOS Monterey+, AirPlay Receiver listens on port 5000 by default.
  # It returns 403 Forbidden to non-AirPlay requests, which breaks registry pushes.
  # Detect this before starting the registry so the user gets a clear error.
  if [[ "$OS" == "darwin" ]]; then
    REGISTRY_CHECK=$(curl -fsSL --max-time 3 http://localhost:5000/v2/ 2>&1 || true)
    if echo "$REGISTRY_CHECK" | grep -q "403\|Forbidden\|AirPlay\|RTSP"; then
      die "Port 5000 is in use by macOS AirPlay Receiver, which conflicts with the local Docker registry.\n\nTo fix: System Settings → General → AirDrop & Handoff → turn off 'AirPlay Receiver'\n\nThen re-run this script."
    fi
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^registry$"; then
    log_ok "Registry container already running"
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^registry$"; then
    log_info "Starting existing registry container..."
    docker start registry
    log_ok "Registry started"
  else
    log_info "Starting new registry container..."
    docker run -d --restart=always -p 5000:5000 --name registry registry:2
    log_ok "Registry started"
  fi

  # Verify the registry is responding correctly (not intercepted by AirPlay or another process).
  # Retry up to 10 times (5 seconds) to allow the container a moment to become ready.
  REGISTRY_V2=""
  for i in {1..10}; do
    REGISTRY_V2=$(curl -fsSL --max-time 3 http://localhost:5000/v2/ 2>/dev/null || echo "")
    if echo "$REGISTRY_V2" | grep -q "{}"; then
      break
    fi
    log_info "Waiting for registry to become ready... (${i}/10)"
    sleep 1
  done
  if ! echo "$REGISTRY_V2" | grep -q "{}"; then
    if [[ "$OS" == "darwin" ]]; then
      die "Local registry on port 5000 is not responding as a Docker registry.\n\nIf you are on macOS Monterey or later, AirPlay Receiver may be using port 5000.\nTo fix: System Settings → General → AirDrop & Handoff → turn off 'AirPlay Receiver'\n\nThen re-run this script."
    else
      die "Local registry on port 5000 is not responding as a Docker registry.\nCheck that the registry container started correctly: docker logs registry"
    fi
  fi
  log_ok "Registry is ready"

  # Require the platform image shipped by the supported public DSP bundle.
  # Merely finding another DSP tag is not enough: a developer registry often
  # retains older images, and selecting one would silently defeat an upgrade.
  DSP_TAGS=$(curl -fsSL http://localhost:5000/v2/virtru/data-security-platform/tags/list 2>/dev/null || echo "")
  if registry_has_dsp_tag "$DSP_TAGS" "$DSP_PLATFORM_IMAGE_TAG"; then
    log_ok "DSP image $DSP_PLATFORM_IMAGE_TAG (bundle $DSP_BUNDLE_RELEASE) found in local registry"
  else
    echo
    if echo "$DSP_TAGS" | grep -q '"tags"'; then
      log_warn "DSP images are present, but required tag $DSP_PLATFORM_IMAGE_TAG is missing."
    else
      log_warn "DSP image not found in local registry."
    fi
    echo
    echo "  Download Virtru DSP bundle release $DSP_BUNDLE_RELEASE from:"
    echo "    https://secure.virtru.com/download"
    echo
    echo "  The bundle must provide platform image tag $DSP_PLATFORM_IMAGE_TAG."
    echo "  Expected layout inside the bundle:"
    echo "    virtru-dsp-bundle/"
    echo "    ├── dsp   (the DSP CLI binary)"
    echo "    └── kubernetes/tagging-pdp-workflows.yaml"
    echo

    # If the prereqs script already unpacked the bundle, use it automatically
    if [[ -n "${BUNDLE_DIR:-}" ]]; then
      log_info "Using bundle selected with --bundle: $BUNDLE_DIR"
    elif [[ -x "$SCRIPT_DIR/virtru-dsp-bundle/dsp" ]] \
      && ensure_bundle_directory_ready "$SCRIPT_DIR/virtru-dsp-bundle"; then
      BUNDLE_DIR="$SCRIPT_DIR/virtru-dsp-bundle"
      log_info "Using bundle unpacked by prereqs: $BUNDLE_DIR"
    else
      BUNDLE_DIR=""
      while true; do
        read -rp "  Enter path to the unpacked Virtru DSP $DSP_BUNDLE_RELEASE bundle directory or .tar.gz archive: " BUNDLE_INPUT
        BUNDLE_INPUT="${BUNDLE_INPUT/#\~/$HOME}"   # expand leading ~
        if [[ -z "$BUNDLE_INPUT" ]]; then
          echo "  Path cannot be empty."
          continue
        fi

        if [[ -f "$BUNDLE_INPUT" ]]; then
          if [[ "$BUNDLE_INPUT" != *.tar.gz ]]; then
            echo "  Expected a Virtru DSP bundle .tar.gz file or an unpacked bundle directory."
            continue
          fi
          if unpack_bundle_archive "$BUNDLE_INPUT"; then
            BUNDLE_DIR="$UNPACKED_BUNDLE_DIR"
            break
          fi
          continue
        fi
        if [[ ! -d "$BUNDLE_INPUT" ]]; then
          echo "  Directory not found: $BUNDLE_INPUT"
          continue
        fi
        if ! ensure_bundle_directory_ready "$BUNDLE_INPUT"; then
          echo "  Make sure the bundle contains a matching DSP CLI archive under tools/dsp/."
          continue
        fi
        BUNDLE_DIR="$BUNDLE_INPUT"
        break
      done
    fi

    if [[ ! -f "$FEDERAL_DST" && -f "$BUNDLE_DIR/samples/defaults/federal.yaml" ]]; then
      cp "$BUNDLE_DIR/samples/defaults/federal.yaml" "$FEDERAL_DST"
      log_ok "Copied $BUNDLE_DIR/samples/defaults/federal.yaml → $FEDERAL_DST"
    fi

    log_info "Loading DSP images from bundle: $BUNDLE_DIR"
    (cd "$BUNDLE_DIR" && ./dsp copy-images --insecure localhost:5000/virtru)

    # Verify that the bundle supplied the exact supported platform release.
    DSP_TAGS=$(curl -fsSL http://localhost:5000/v2/virtru/data-security-platform/tags/list 2>/dev/null || echo "")
    if registry_has_dsp_tag "$DSP_TAGS" "$DSP_PLATFORM_IMAGE_TAG"; then
      log_ok "DSP image $DSP_PLATFORM_IMAGE_TAG loaded successfully"
    else
      AVAILABLE_DSP_TAGS=$(jq -r '(.tags // []) | join(", ")' <<<"$DSP_TAGS" 2>/dev/null || echo "none")
      die "The selected bundle did not provide required platform image $DSP_PLATFORM_IMAGE_TAG (DSP bundle $DSP_BUNDLE_RELEASE).\nAvailable registry tags: ${AVAILABLE_DSP_TAGS:-none}\nDownload the supported bundle from https://secure.virtru.com/download and retry."
    fi
  fi

fi  # end prerequisites block

# The release bundle also supplies tructl and the tagging workflow. Validate
# the local bundle even when the matching container image was already present
# in the registry so host tooling cannot remain on an older release.
if [[ "$SDK_ONLY" == false && -z "${BUNDLE_DIR:-}" ]]; then
  BUNDLE_DIR="$SCRIPT_DIR/virtru-dsp-bundle"
  if [[ ! -d "$BUNDLE_DIR" ]] || ! ensure_bundle_directory_ready "$BUNDLE_DIR"; then
    die "Virtru DSP bundle $DSP_BUNDLE_RELEASE is required for its $DSP_PLATFORM_IMAGE_TAG CLI and tagging configuration.\nUnpack the supported bundle at $BUNDLE_DIR or pass --bundle /path/to/bundle and retry."
  fi
fi

# ---------------------------------------------------------------------------
# Resolve + stage tagging workflow before start/validation
# ---------------------------------------------------------------------------
if [[ "$SDK_ONLY" == false ]]; then
  log_section "Resolving tagging PDP workflow"
  resolve_tagging_pdp_workflow_source "${BUNDLE_DIR:-}"
  stage_tagging_pdp_workflow "$TAGGING_PDP_WORKFLOW_SOURCE"

  if [[ "$VALIDATE_ONLY" == true && "$TAGGING_PDP_WORKFLOW_CHANGED" == true ]]; then
    if docker compose ps dsp 2>/dev/null | grep -qiE "Up|running|healthy"; then
      log_section "Restarting DSP to apply updated tagging workflow"
      docker compose restart dsp
      log_info "Waiting for DSP /healthz after restart..."
      for _ in {1..18}; do
        if curl -fksSo /dev/null --max-time 5 https://local-dsp.virtru.com:8080/healthz 2>/dev/null; then
          log_ok "DSP is healthy after tagging workflow restart"
          break
        fi
        sleep 5
      done
    else
      log_warn "DSP is not currently running, so the updated tagging workflow was staged but not applied."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Detect DSP image tag from registry + start the stack
# ---------------------------------------------------------------------------
if [[ "$VALIDATE_ONLY" == false ]]; then

  log_section "Detecting DSP image version"

  DSP_TAGS=$(curl -fsSL http://localhost:5000/v2/virtru/data-security-platform/tags/list 2>/dev/null || echo "")
  if ! registry_has_dsp_tag "$DSP_TAGS" "$DSP_PLATFORM_IMAGE_TAG"; then
    die "Required DSP image $DSP_PLATFORM_IMAGE_TAG is not available in the local registry.\nLoad Virtru DSP bundle $DSP_BUNDLE_RELEASE and retry."
  fi

  DSP_TAG="$DSP_PLATFORM_IMAGE_TAG"
  DSP_IMAGE="localhost:5000/virtru/data-security-platform:${DSP_TAG}"
  log_ok "DSP bundle: $DSP_BUNDLE_RELEASE | platform image: $DSP_IMAGE"

  log_section "Starting Docker Compose stack"

  # On Linux, strip the 'sharepoint' block from dsp.yaml before the build —
  # this DSP version does not recognise 'encryptedSearchKeyPath' and refuses
  # to start with a config validation error. The host file is restored after
  # the build so macOS checkouts are unaffected.
  if [[ "$OS" == "linux" ]]; then
    cp dsp.yaml dsp.yaml.bak
    python3 -c "
import re, sys
content = open('dsp.yaml').read()
content = re.sub(r'\n  sharepoint:\n(?:    [^\n]*\n)*', '\n', content)
open('dsp.yaml', 'w').write(content)
"
    log_info "dsp.yaml patched for Linux (sharepoint block removed)"
  fi

  if [[ "$NO_BUILD" == true ]]; then
    log_info "Running: docker compose up -d (--no-build: using cached images)"
    docker compose up -d
  else
    log_info "Running: docker compose build --build-arg DSP_IMAGE=${DSP_IMAGE}"
    docker compose build --build-arg "DSP_IMAGE=${DSP_IMAGE}"
    log_info "Running: docker compose up -d"
    docker compose up -d
  fi

  # Restore original dsp.yaml now that the image is built
  if [[ "$OS" == "linux" && -f dsp.yaml.bak ]]; then
    mv dsp.yaml.bak dsp.yaml
    log_info "dsp.yaml restored"
  fi

  log_ok "Stack started in detached mode"

  # Wait for DSP to become healthy
  log_section "Waiting for DSP to become healthy"
  log_info "Polling https://local-dsp.virtru.com:8080/healthz (timeout: 3 minutes)..."

  TIMEOUT=180
  ELAPSED=0
  INTERVAL=10
  until curl -fksSo /dev/null --max-time 5 https://local-dsp.virtru.com:8080/healthz 2>/dev/null; do
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      echo
      log_warn "DSP did not respond to /healthz within ${TIMEOUT}s — continuing to SDK tests."
      log_warn "The container may still be initialising. Check: docker compose logs dsp"
      break
    fi
    printf "    Waiting... %ds elapsed\r" "$ELAPSED"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  echo
  if curl -fksSo /dev/null --max-time 5 https://local-dsp.virtru.com:8080/healthz 2>/dev/null; then
    log_ok "DSP is healthy (${ELAPSED}s elapsed)"
  fi

fi

if namespace_requested company; then
  provision_company_namespace
fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
ERRORS=()

if [[ "$SDK_ONLY" == true ]]; then
  log_section "Skipping infra checks (--sdk-only)"
else
  log_section "Running validation checks"

# --- 1. Container status ----------------------------------------------------
log_info "Check 1: Container status"

for svc in keycloak-db keycloak dsp-db dsp; do
  if docker compose ps "$svc" 2>/dev/null | grep -qiE "Up|running|healthy"; then
    check_pass "$svc is running"
  else
    check_fail "$svc is NOT running"
    ERRORS+=("$svc container not running")
  fi
done

  log_info "Check 1a: DSP platform version"
  DSP_VERSION_OUTPUT=$(docker compose exec -T dsp /usr/bin/dsp version 2>&1 || true)
  DSP_REPORTED_VERSION=$(awk '$1 == "Version:" { print $2; exit }' <<<"$DSP_VERSION_OUTPUT")
  DSP_EXPECTED_VERSION="${DSP_PLATFORM_IMAGE_TAG#v}"
  DSP_REPORTED_VERSION="${DSP_REPORTED_VERSION#v}"
  if [[ "$DSP_REPORTED_VERSION" == "$DSP_EXPECTED_VERSION" ]]; then
    check_pass "DSP platform version is $DSP_PLATFORM_IMAGE_TAG (bundle $DSP_BUNDLE_RELEASE)"
  else
    check_fail "DSP platform version is not $DSP_PLATFORM_IMAGE_TAG (got: ${DSP_REPORTED_VERSION:-no response})"
    ERRORS+=("DSP platform version mismatch — expected $DSP_PLATFORM_IMAGE_TAG from bundle $DSP_BUNDLE_RELEASE")
  fi

  # Wait for one-shot provisioning containers to reach Exited (0)
  log_info "Check 1b: Waiting for provisioning containers to complete"

  for svc in dsp-keycloak-provisioning dsp-provision-federal-policy; do
    CONTAINER="virtru-dsp-only-${svc}-1"
    MAX_ATTEMPTS=4
    ATTEMPT=0
    PROVISIONED=false
    while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
      ATTEMPT=$((ATTEMPT + 1))
      CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "")
      CONTAINER_EXIT=$(docker inspect --format='{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo "-1")
      if [[ "$CONTAINER_STATUS" == "exited" && "$CONTAINER_EXIT" == "0" ]]; then
        check_pass "$svc ($CONTAINER) exited cleanly (0)"
        PROVISIONED=true
        break
      fi
      log_info "$svc status: ${CONTAINER_STATUS:-not found} / exit: ${CONTAINER_EXIT} (attempt $ATTEMPT/$MAX_ATTEMPTS) — waiting 15s..."
      sleep 15
    done
    if [[ "$PROVISIONED" == false ]]; then
      log_warn "$svc did not reach exited(0) after $MAX_ATTEMPTS attempts — continuing with warning"
      log_warn "Last status: ${CONTAINER_STATUS:-unknown}  exit code: ${CONTAINER_EXIT:-unknown}"
      log_warn "To inspect: docker compose logs $svc"
    fi
  done

# --- 2. DSP health endpoint -------------------------------------------------
log_info "Check 2: DSP health endpoint"

HEALTH=$(curl -fksSo - --max-time 10 https://local-dsp.virtru.com:8080/healthz 2>/dev/null || echo "")
if echo "$HEALTH" | grep -q "SERVING"; then
  check_pass "DSP /healthz → SERVING"
else
  check_fail "DSP /healthz did not return SERVING (got: ${HEALTH:-no response})"
  ERRORS+=("DSP health check failed")
fi

# --- 3. Keycloak realm reachable --------------------------------------------
log_info "Check 3: Keycloak realm"

REALM=$(curl -fksSo - --max-time 10 \
  https://local-dsp.virtru.com:18443/auth/realms/opentdf 2>/dev/null \
  | jq -r '.realm' 2>/dev/null || echo "")
if [[ "$REALM" == "opentdf" ]]; then
  check_pass "Keycloak realm 'opentdf' is reachable"
else
  check_fail "Keycloak realm check failed (got: ${REALM:-no response})"
  ERRORS+=("Keycloak realm not reachable")
fi

# --- 3b. Optional Keycloak users -------------------------------------------
if namespace_requested company; then
  log_info "Check 3b: Company namespace Keycloak users"

  ADMIN_TOKEN=$(get_keycloak_admin_token)
  if [[ -n "$ADMIN_TOKEN" ]] && company_users_are_present "$ADMIN_TOKEN"; then
    check_pass "Company namespace users are present in Keycloak"
  else
    check_fail "Company namespace users not found in Keycloak"
    ERRORS+=("Company namespace users missing from Keycloak")
  fi
fi

# --- 4. Obtain token --------------------------------------------------------
log_info "Check 4: Obtain service account token"

TOKEN=$(get_service_account_token)

if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
  check_pass "Token obtained from Keycloak"
else
  check_fail "Failed to obtain token from Keycloak"
  ERRORS+=("Could not obtain token — subsequent checks will fail")
fi

# --- 5. DSP attributes provisioned ------------------------------------------
log_info "Check 5: DSP attributes"

if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
  ATTRS="$(list_policy_attribute_pairs "$TOKEN")"
  REQUIRED_ATTRS=(
    "demo.com/classification"
    "demo.com/needtoknow"
    "demo.com/relto"
  )
  if namespace_requested company; then
    REQUIRED_ATTRS+=(
      "company.com/classification"
      "company.com/department"
      "company.com/sensitivity"
    )
  fi

  MISSING_ATTRS=()
  for expected in "${REQUIRED_ATTRS[@]}"; do
    if ! grep -qx "$expected" <<<"$ATTRS"; then
      MISSING_ATTRS+=("$expected")
    fi
  done

  if [[ ${#MISSING_ATTRS[@]} -eq 0 ]]; then
    check_pass "Required policy attributes found: $(printf '%s ' "${REQUIRED_ATTRS[@]}")"
  else
    check_fail "Missing required attributes: ${MISSING_ATTRS[*]}"
    ERRORS+=("Required policy attributes not provisioned correctly")
  fi
else
  check_fail "Skipping attribute check (no token)"
  ERRORS+=("Attribute check skipped — no token")
fi

# --- 6. Database connectivity -----------------------------------------------
log_info "Check 6: Database connectivity"

DSP_TABLES=$(docker exec virtru-dsp-only-dsp-db-1 \
  psql -U postgres -d opentdf -c "\dt dsp_policy.*" 2>/dev/null | grep -c "row" || echo "0")
if [[ "$DSP_TABLES" -gt 0 ]]; then
  check_pass "DSP policy schema has tables in opentdf DB"
else
  check_fail "No tables found in dsp_policy schema"
  ERRORS+=("DSP policy schema empty or missing")
fi

KC_TABLES=$(docker exec virtru-dsp-only-keycloak-db-1 psql -U postgres -d keycloak -c "\dt *" 2>/dev/null | grep -c "row" || echo "0")
if [[ "$KC_TABLES" -gt 0 ]]; then
  check_pass "Keycloak DB has tables"
else
  check_fail "No tables found in Keycloak DB"
  ERRORS+=("Keycloak DB empty or missing")
fi

fi  # end infra checks (skipped when --sdk-only)

# ---------------------------------------------------------------------------
# SDK validation runs by default; --sdk-only skips the infrastructure checks.
# ---------------------------------------------------------------------------

# Helper: print captured output indented inside a labeled box
print_program_output() {
  local label="$1"
  local output="$2"
  echo
  echo -e "    ${BOLD}┌─ ${label} output ──────────────────────────────────────────${NC}"
  echo "$output" | while IFS= read -r line; do
    echo -e "    ${BOLD}│${NC}  $line"
  done
  echo -e "    ${BOLD}└───────────────────────────────────────────────────────────${NC}"
  echo
}

if [[ "$SDK_VALIDATION" == "true" ]]; then
  log_section "SDK Validation (Go programs)"

  SDK_DIR="$SCRIPT_DIR"
  SDK_RUNTIME_DIR="$GENERATED_DIR/sdk"
  GO_CACHE_ROOT="$GENERATED_DIR/go"
  export GOPATH="${GOPATH:-$GO_CACHE_ROOT}"
  export GOMODCACHE="${GOMODCACHE:-$GO_CACHE_ROOT/pkg/mod}"
  export GOCACHE="${GOCACHE:-$GO_CACHE_ROOT/build}"
  mkdir -p "$SDK_RUNTIME_DIR" "$GOMODCACHE" "$GOCACHE"

  # Verify Go is installed
  if ! command -v go &> /dev/null; then
    check_fail "Go is not installed — cannot run SDK validation"
    ERRORS+=("Go not found; install Go and rerun validation")
  else
    log_ok "Go found: $(go version)"
    log_info "Using committed SDK module: $SDK_DIR"
    log_info "Using generated SDK runtime directory: $SDK_RUNTIME_DIR"
    log_info "Using Go cache root: $GO_CACHE_ROOT"
    log_info "First-run Go dependency downloads can take a few minutes."

    # --- Validate the committed Go module -----------------------------------
    log_info "Checking go.mod..."

    GOMOD="$SDK_DIR/go.mod"
    EXPECTED_MODULE="github.com/virtru/dsp-standalone"
    EXPECTED_SDK="github.com/opentdf/platform/sdk"
    EXPECTED_OAUTH="golang.org/x/oauth2"

    GOMOD_OK=true

    if [[ ! -f "$GOMOD" ]]; then
      log_warn "go.mod not found"
      GOMOD_OK=false
    else
      # Verify the module name and required direct dependencies are present
      if ! grep -q "^module ${EXPECTED_MODULE}$" "$GOMOD"; then
        log_warn "go.mod module name is not '${EXPECTED_MODULE}'"
        GOMOD_OK=false
      fi
      if ! grep -q "^[[:space:]]*${EXPECTED_SDK}[[:space:]]" "$GOMOD"; then
        log_warn "go.mod is missing direct dependency: ${EXPECTED_SDK}"
        GOMOD_OK=false
      fi
      if ! grep -q "^[[:space:]]*${EXPECTED_OAUTH}[[:space:]]" "$GOMOD"; then
        log_warn "go.mod is missing direct dependency: ${EXPECTED_OAUTH}"
        GOMOD_OK=false
      fi
    fi

    if [[ "$GOMOD_OK" == false ]]; then
      check_fail "go.mod is missing or invalid"
      ERRORS+=("go.mod is missing or invalid — restore the committed module before running SDK validation")
      log_warn "Skipping SDK builds because the committed Go module is unavailable"
    else
      check_pass "go.mod is present and contains the expected dependencies"

      # Load and verify the committed dependency graph without rewriting it.
      log_info "Downloading and verifying Go modules..."
      MODULES_OK=true
      if (cd "$SDK_DIR" && go mod download && go mod verify 2>&1); then
        check_pass "Go modules downloaded and verified"
      else
        check_fail "Go module download or verification failed"
        ERRORS+=("Go module verification failed — check go.mod, go.sum, and network connectivity")
        MODULES_OK=false
      fi

      if [[ "$MODULES_OK" == false ]]; then
        log_warn "Skipping SDK builds because Go module verification failed"
      else
        # --- Build all programs first ----------------------------------------
        log_info "Building Go programs..."
        BUILD_DIR=$(mktemp -d)

        BIN_TOY="$BUILD_DIR/toySDK"
        BIN_BOB="$BUILD_DIR/bobTestAlexFile"
        BIN_ALICE="$BUILD_DIR/aliceTestAlexFile"
        BIN_COMPANY="$BUILD_DIR/companyNamespaceValidation"

        BUILD_OK=true
        BUILD_TARGETS=(
          "./cmd/toy-sdk:$BIN_TOY"
          "./cmd/bob-test-alex-file:$BIN_BOB"
          "./cmd/alice-test-alex-file:$BIN_ALICE"
        )
        if namespace_requested company; then
          BUILD_TARGETS+=("./cmd/company-namespace-validation:$BIN_COMPANY")
        fi

        for target in "${BUILD_TARGETS[@]}"; do
          src="${target%%:*}"
          bin="${target#*:}"
          BUILD_OUTPUT=$(cd "$SDK_DIR" && go build -o "$bin" "$src" 2>&1) && BUILD_RC=0 || BUILD_RC=$?
          if [[ $BUILD_RC -eq 0 ]]; then
            check_pass "Built $src"
          else
            check_fail "Failed to build $src (exit $BUILD_RC)"
            echo "$BUILD_OUTPUT" | while IFS= read -r line; do log_fail "  $line"; done
            ERRORS+=("Build failed: $src — fix compile errors before running SDK tests")
            BUILD_OK=false
          fi
        done

        if [[ "$BUILD_OK" == false ]]; then
          log_warn "Skipping SDK test runs due to build failures above"
        else

          # --- toy-sdk: Alex encrypts a file ---------------------------------
          log_info "Running toy-sdk (Alex creates alex_test.tdf)..."
          TOY_OUTPUT=$(cd "$SDK_RUNTIME_DIR" && "$BIN_TOY" 2>&1) && TOY_RC=0 || TOY_RC=$?
          print_program_output "toy-sdk" "$TOY_OUTPUT"
          if [[ $TOY_RC -eq 0 ]]; then
            check_pass "toy-sdk: Alex successfully encrypted and decrypted the TDF"
          else
            check_fail "toy-sdk failed (exit $TOY_RC)"
            ERRORS+=("toy-sdk failed — Alex could not create TDF")
          fi

          # --- Bob (TS/GBR) should decrypt Alex's file -----------------------
          log_info "Running bob-test-alex-file (Bob reads Alex's file)..."
          BOB_OUTPUT=$(cd "$SDK_RUNTIME_DIR" && "$BIN_BOB" 2>&1) && BOB_RC=0 || BOB_RC=$?
          print_program_output "bob-test-alex-file" "$BOB_OUTPUT"
          if [[ $BOB_RC -eq 0 ]]; then
            check_pass "bob-test-alex-file: Bob successfully decrypted Alex's file (FVEY + TS access)"
          else
            check_fail "bob-test-alex-file failed (exit $BOB_RC)"
            ERRORS+=("bob-test-alex-file failed — Bob should be able to decrypt Alex's file")
          fi

          # --- Alice (S/USA) should be denied --------------------------------
          log_info "Running alice-test-alex-file (Alice denied Alex's file)..."
          ALICE_OUTPUT=$(cd "$SDK_RUNTIME_DIR" && "$BIN_ALICE" 2>&1) && ALICE_RC=0 || ALICE_RC=$?
          print_program_output "alice-test-alex-file" "$ALICE_OUTPUT"
          if [[ $ALICE_RC -eq 0 ]]; then
            check_pass "alice-test-alex-file: KAS correctly denied Alice access to Top Secret file"
          else
            check_fail "alice-test-alex-file failed (exit $ALICE_RC) — expected denial to succeed"
            ERRORS+=("alice-test-alex-file: access denial test did not succeed as expected")
          fi

          if namespace_requested company; then
            log_info "Running company-namespace-validation (company namespace access test)..."
            COMPANY_OUTPUT=$(cd "$SDK_RUNTIME_DIR" && "$BIN_COMPANY" 2>&1) && COMPANY_RC=0 || COMPANY_RC=$?
            print_program_output "company-namespace-validation" "$COMPANY_OUTPUT"
            if [[ $COMPANY_RC -eq 0 ]]; then
              check_pass "company-namespace-validation: company namespace users and policy behaved as expected"
            else
              check_fail "company-namespace-validation failed (exit $COMPANY_RC)"
              ERRORS+=("company-namespace-validation failed — company namespace validation did not succeed")
            fi
          fi
        fi

        rm -rf "$BUILD_DIR"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Tagging Validation
# ---------------------------------------------------------------------------
if [[ "$SDK_ONLY" == true ]]; then
  log_section "Skipping tagging validation (--sdk-only)"
else
  log_section "Tagging Validation"
  TAGGING_TEST_ARGS=(--namespace federal)
  if namespace_requested company; then
    TAGGING_TEST_ARGS+=(--namespace company)
  fi

  if bash "$SCRIPT_DIR/test_tagging.sh" "${TAGGING_TEST_ARGS[@]}"; then
    check_pass "Tagging validation passed"
  else
    check_fail "Tagging validation failed"
    ERRORS+=("Tagging validation failed — inspect test_tagging.sh output")
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_section "Validation summary"

echo -e "    Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
echo

if [[ ${#ERRORS[@]} -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}All checks passed. DSP stack is healthy.${NC}"
  echo
  echo "  Keycloak admin: https://local-dsp.virtru.com:18443/auth"
  echo "  DSP services:   https://local-dsp.virtru.com:8080"
  echo
  exit 0
else
  echo -e "  ${RED}${BOLD}The following checks failed:${NC}"
  for err in "${ERRORS[@]}"; do
    echo -e "    ${RED}✗${NC} $err"
  done
  echo
  echo "  Troubleshooting:"
  echo "    docker compose logs dsp"
  echo "    docker compose logs keycloak"
  echo "    docker compose ps"
  echo
  exit 1
fi
