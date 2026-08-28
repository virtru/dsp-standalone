#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${HOST:-https://local-dsp.virtru.com:8080}"
CLIENT_CREDS="${CLIENT_CREDS:-{\"clientId\":\"opentdf\",\"clientSecret\":\"secret\"}}"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/.generated/tagging-pdp-workflows.yaml}"

PASS=0
FAIL=0
REQUESTED_NAMESPACES=()
FEDERAL_SUITE_FAILED=0
COMPANY_SUITE_FAILED=0
FEDERAL_SUITE_RAN=0
COMPANY_SUITE_RAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ $# -ge 2 ]] || { echo "FATAL: --namespace requires a value (federal|company)" >&2; exit 1; }
      REQUESTED_NAMESPACES+=("$2")
      shift 2
      ;;
    --namespace=*)
      REQUESTED_NAMESPACES+=("${1#*=}")
      shift
      ;;
    *)
      echo "FATAL: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

log_section() { echo; echo "==> $*"; }
log_info()    { echo "    · $*"; }
log_ok()      { echo "    ✓ $*"; }
log_fail()    { echo "    ✗ $*"; }

record_pass() { log_ok "$1"; ((PASS++)) || true; }
record_fail() { log_fail "$1"; ((FAIL++)) || true; }

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

  if [[ ${#REQUESTED_NAMESPACES[@]} -eq 0 ]]; then
    REQUESTED_NAMESPACES=(federal company)
    return 0
  fi

  for ns in "${REQUESTED_NAMESPACES[@]}"; do
    case "$ns" in
      federal|company)
        if [[ ${#normalized[@]} -eq 0 ]] || ! contains_item "$ns" "${normalized[@]}"; then
          normalized+=("$ns")
        fi
        ;;
      *)
        echo "FATAL: Unsupported namespace '$ns'. Supported values: federal, company" >&2
        exit 1
        ;;
    esac
  done

  REQUESTED_NAMESPACES=("${normalized[@]}")
}

namespace_requested() {
  contains_item "$1" "${REQUESTED_NAMESPACES[@]}"
}

find_tructl() {
  if [[ -n "${TRUCTL:-}" && -x "${TRUCTL}" ]]; then
    printf '%s\n' "$TRUCTL"
    return 0
  fi

  local candidates=(
    "$SCRIPT_DIR/virtru-dsp-bundle/tructl"
    "$SCRIPT_DIR/virtru-dsp-bundle"/tools/dsp/*/tructl
    "$SCRIPT_DIR"/virtru-dsp-bundle-*/tructl
    "$SCRIPT_DIR"/virtru-dsp-bundle-*/tools/dsp/*/tructl
  )
  local candidate=""
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

normalize_tags() {
  jq -r '.tags[]? | .Value.DataAttribute.fqn? // empty' \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u
}

filter_tags_for_namespace() {
  local namespace="$1"
  local prefix=""

  case "$namespace" in
    federal) prefix="https://demo.com/" ;;
    company) prefix="https://company.com/" ;;
    *) cat; return 0 ;;
  esac

  awk -v prefix="$prefix" 'index($0, prefix) == 1'
}

run_remote_tagging() {
  local file_path="$1"
  "$TRUCTL_BIN" tag "$file_path" \
    --host "$HOST" \
    --tls-no-verify \
    --with-client-creds "$CLIENT_CREDS" \
    --json
}

run_local_tagging() {
  local file_path="$1"
  "$TRUCTL_BIN" tag "$file_path" \
    --local \
    --config-file "$CONFIG_FILE" \
    --json
}

compare_sets() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [[ "$actual" == "$expected" ]]; then
    record_pass "$label"
    return 0
  else
    record_fail "$label"
    log_info "Expected tags:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "      $line"
    done <<< "$expected"
    log_info "Actual tags:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "      $line"
    done <<< "$actual"
    return 1
  fi
}

run_case() {
  local namespace="$1"
  local case_name="$2"
  local file_path="$3"
  local expected="$4"
  local suite_failed=0

  log_info "Case [$namespace]: $case_name"

  local remote_json=""
  local local_json=""
  local remote_tags=""
  local local_tags=""
  local remote_namespace_tags=""
  local local_namespace_tags=""

  if ! remote_json="$(run_remote_tagging "$file_path" 2>"$TMP_DIR/${namespace}.${case_name}.remote.log")"; then
    record_fail "$namespace/$case_name: remote tructl tag failed"
    sed -n '1,40p' "$TMP_DIR/${namespace}.${case_name}.remote.log" | while IFS= read -r line; do
      [[ -n "$line" ]] && echo "      $line"
    done
    return 1
  fi

  if ! local_json="$(run_local_tagging "$file_path" 2>"$TMP_DIR/${namespace}.${case_name}.local.log")"; then
    record_fail "$namespace/$case_name: local tructl tag failed"
    sed -n '1,40p' "$TMP_DIR/${namespace}.${case_name}.local.log" | while IFS= read -r line; do
      [[ -n "$line" ]] && echo "      $line"
    done
    return 1
  fi

  remote_tags="$(printf '%s\n' "$remote_json" | normalize_tags)"
  local_tags="$(printf '%s\n' "$local_json" | normalize_tags)"
  remote_namespace_tags="$(printf '%s\n' "$remote_tags" | filter_tags_for_namespace "$namespace")"
  local_namespace_tags="$(printf '%s\n' "$local_tags" | filter_tags_for_namespace "$namespace")"

  compare_sets "$namespace/$case_name: remote tags match expected attributes" "$expected" "$remote_namespace_tags" || suite_failed=1
  compare_sets "$namespace/$case_name: local tags match expected attributes" "$expected" "$local_namespace_tags" || suite_failed=1
  compare_sets "$namespace/$case_name: remote tagging matches staged local config" "$local_namespace_tags" "$remote_namespace_tags" || suite_failed=1

  [[ "$suite_failed" -eq 0 ]]
}

run_federal_suite() {
  FEDERAL_SUITE_RAN=1
  local suite_failed=0
  local expected_secret expected_confidential expected_unclassified

  cat > "$TMP_DIR/secret-relto.txt" <<'EOF'
SECRET REL TO US UK
Operational note follows.
EOF

  cat > "$TMP_DIR/confidential-relto.txt" <<'EOF'
CONFIDENTIAL REL TO US
Distribution is limited.
EOF

  cat > "$TMP_DIR/unclassified-relto.txt" <<'EOF'
UNCLASSIFIED REL TO UK
Release approved.
EOF

  expected_secret="$(cat <<'EOF'
https://demo.com/attr/classification/value/secret
https://demo.com/attr/relto/value/gbr
https://demo.com/attr/relto/value/usa
EOF
)"
  expected_confidential="$(cat <<'EOF'
https://demo.com/attr/classification/value/confidential
https://demo.com/attr/relto/value/usa
EOF
)"
  expected_unclassified="$(cat <<'EOF'
https://demo.com/attr/classification/value/unclassified
https://demo.com/attr/relto/value/gbr
EOF
)"

  run_case federal "secret-relto-fvey" "$TMP_DIR/secret-relto.txt" "$expected_secret" || suite_failed=1
  run_case federal "confidential-relto-usa" "$TMP_DIR/confidential-relto.txt" "$expected_confidential" || suite_failed=1
  run_case federal "unclassified-relto-gbr" "$TMP_DIR/unclassified-relto.txt" "$expected_unclassified" || suite_failed=1

  FEDERAL_SUITE_FAILED="$suite_failed"
}

run_company_suite() {
  COMPANY_SUITE_RAN=1
  local suite_failed=0
  local expected_confidential expected_public

  cat > "$TMP_DIR/company-confidential.json" <<'EOF'
{"sensitivity":"confidential","classification":["mnpi","pii"]}
EOF

  cat > "$TMP_DIR/company-public.json" <<'EOF'
{"sensitivity":"public","classification":["phi"]}
EOF

  expected_confidential="$(cat <<'EOF'
https://company.com/attr/classification/value/mnpi
https://company.com/attr/classification/value/pii
https://company.com/attr/sensitivity/value/confidential
EOF
)"
  expected_public="$(cat <<'EOF'
https://company.com/attr/classification/value/phi
https://company.com/attr/sensitivity/value/public
EOF
)"

  run_case company "confidential-mnpi-pii" "$TMP_DIR/company-confidential.json" "$expected_confidential" || suite_failed=1
  run_case company "public-phi" "$TMP_DIR/company-public.json" "$expected_public" || suite_failed=1

  COMPANY_SUITE_FAILED="$suite_failed"
}

print_mixed_namespace_hint() {
  if [[ "$FEDERAL_SUITE_RAN" -eq 1 && "$COMPANY_SUITE_RAN" -eq 1 ]]; then
    if [[ "$FEDERAL_SUITE_FAILED" -eq 0 && "$COMPANY_SUITE_FAILED" -ne 0 ]]; then
      echo
      log_fail "Federal tagging passed but company tagging failed."
      log_info "This usually means the staged tagging workflow or DSP policy is still federal-only."
      log_info "Re-run setup with: ./setup_and_validate.sh --add-namespace company"
    elif [[ "$FEDERAL_SUITE_FAILED" -ne 0 && "$COMPANY_SUITE_FAILED" -eq 0 ]]; then
      echo
      log_fail "Company tagging passed but federal tagging failed."
      log_info "This usually means the staged tagging workflow is not additive or the federal workflow was replaced."
      log_info "Re-run setup without removing the federal tagging workflow, or inspect $CONFIG_FILE."
    fi
  fi
}

main() {
  normalize_requested_namespaces

  log_section "Tagging validation"

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for tagging validation." >&2
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required for tagging validation." >&2
    exit 1
  fi

  if ! curl -fksS --max-time 5 "$HOST/healthz" >/dev/null 2>&1; then
    echo "DSP is not reachable at $HOST" >&2
    exit 1
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Tagging config file not found: $CONFIG_FILE" >&2
    exit 1
  fi

  if ! TRUCTL_BIN="$(find_tructl)"; then
    echo "Could not find tructl inside the unpacked DSP bundle." >&2
    exit 1
  fi

  log_ok "Using tructl: $TRUCTL_BIN"
  log_ok "Using tagging config: $CONFIG_FILE"
  log_ok "Namespaces under test: ${REQUESTED_NAMESPACES[*]}"

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  namespace_requested federal && run_federal_suite
  namespace_requested company && run_company_suite

  print_mixed_namespace_hint

  echo
  echo "    Passed: $PASS   Failed: $FAIL"

  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
