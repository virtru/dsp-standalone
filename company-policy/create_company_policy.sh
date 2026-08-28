#!/usr/bin/env bash
#
# Construct the company.com policy in a running local DSP using tructl, then
# export it. Idempotent on the namespace; attribute/mapping creates will error
# if the policy already exists (deactivate or use a fresh stack to re-run).
#
# Requires a running dsp-standalone (or other local DSP) reachable at $HOST and
# the `tructl` binary (from the DSP bundle or on PATH). jq is required.
#
# Usage:
#   ./create_company_policy.sh
#   HOST=https://local-dsp.virtru.com:8080 TRUCTL=/path/to/tructl ./create_company_policy.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${HOST:-https://local-dsp.virtru.com:8080}"
CLIENT_CREDS="${CLIENT_CREDS:-{\"clientId\":\"opentdf\",\"clientSecret\":\"secret\"}}"
NAMESPACE="${NAMESPACE:-company.com}"
EXPORT_FILE="${EXPORT_FILE:-$SCRIPT_DIR/company.com-export.yaml}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

locate_tructl() {
  if [[ -n "${TRUCTL:-}" ]]; then printf '%s' "$TRUCTL"; return; fi
  local c
  for c in \
    "$SCRIPT_DIR"/../virtru-dsp-bundle*/tructl \
    "$SCRIPT_DIR"/../.generated/virtru-dsp-bundle-*/tructl; do
    if [[ -x "$c" ]]; then printf '%s' "$c"; return; fi
  done
  command -v tructl 2>/dev/null || { echo "tructl not found; set TRUCTL=/path/to/tructl" >&2; exit 1; }
}
TRUCTL="$(locate_tructl)"
echo "Using tructl: $TRUCTL  (host: $HOST)"

# tructl wrapper: authenticated, JSON output.
t() { "$TRUCTL" --host "$HOST" --tls-no-verify --with-client-creds "$CLIENT_CREDS" --json "$@"; }

# Build a "subject sets" JSON array entitling any subject whose Keycloak
# `dept` attribute is IN the given list (operator 1 = IN).
scs_for_depts() {
  local vals=""
  local d
  for d in "$@"; do vals+="\"$d\","; done
  vals="[${vals%,}]"
  printf '[{"condition_groups":[{"boolean_operator":1,"conditions":[{"subject_external_selector_value":".attributes.dept[]","operator":1,"subject_external_values":%s}]}]}]' "$vals"
}

# Resolve a value id by (case-insensitive) value name from an attribute JSON.
# Uses recursive descent so it works whether the response is the attribute
# object directly or wrapped (e.g. {"attribute": {...}}).
val_id() {
  echo "$1" | jq -r --arg v "$2" \
    '[.. | objects | select((.value? | type) == "string" and (.value|ascii_downcase) == ($v|ascii_downcase))][0].id // empty'
}

# Create an attribute (with inline values) under the namespace.
create_attr() { # name rule value...
  local name="$1" rule="$2"; shift 2
  local args=(policy attributes create -s "$NS_ID" -n "$name" -r "$rule")
  local v
  for v in "$@"; do args+=(-v "$v"); done
  t "${args[@]}"
}

# Create a subject mapping: value id -> a new subject condition set over depts.
map_value_to_depts() { # value_id dept...
  local vid="$1"; shift
  [[ -n "$vid" ]] || { echo "missing value id" >&2; exit 1; }
  t policy subject-mappings create -a "$vid" --action read \
    --subject-condition-set-new "$(scs_for_depts "$@")" >/dev/null
}

# --- Namespace (get-or-create) -------------------------------------------------
NS_ID="$(t policy attributes namespaces list 2>/dev/null \
  | jq -r --arg n "$NAMESPACE" '[.. | objects | select(.name? == $n and ((.fqn? // "") | contains("/attr/") | not))][0].id // empty')"
if [[ -z "$NS_ID" ]]; then
  NS_ID="$(t policy attributes namespaces create -n "$NAMESPACE" | jq -r --arg n "$NAMESPACE" '[.. | objects | select(.name? == $n)][0].id // empty')"
  echo "Created namespace $NAMESPACE ($NS_ID)"
else
  echo "Namespace $NAMESPACE already exists ($NS_ID)"
fi
[[ -n "$NS_ID" ]] || { echo "failed to resolve namespace id" >&2; exit 1; }

# --- Department (ANY_OF) -------------------------------------------------------
# A subject is entitled to the department value matching their own dept claim.
DEPT_JSON="$(create_attr department ANY_OF Engineering HR Accounting Sales)"
map_value_to_depts "$(val_id "$DEPT_JSON" engineering)" Engineering
map_value_to_depts "$(val_id "$DEPT_JSON" hr)"          HR
map_value_to_depts "$(val_id "$DEPT_JSON" accounting)"  Accounting
map_value_to_depts "$(val_id "$DEPT_JSON" sales)"       Sales
echo "Created department (ANY_OF) + 4 subject mappings"

# --- Sensitivity (HIERARCHY: confidential > public) ----------------------------
# Value order defines the hierarchy; confidential is highest. Any internal user
# (i.e. holding ANY dept value) is entitled to confidential, which under the
# hierarchy rule also grants access to public-tagged data.
SENS_JSON="$(create_attr sensitivity HIERARCHY confidential public)"
map_value_to_depts "$(val_id "$SENS_JSON" confidential)" Engineering HR Accounting Sales
echo "Created sensitivity (HIERARCHY) + confidential subject mapping"

# --- Classification (ALL_OF) ---------------------------------------------------
# Per-value entitlement by department:
#   MNPI -> all departments
#   PII  -> HR, Accounting, Sales
#   PCI  -> Accounting
#   PHI  -> HR
CLS_JSON="$(create_attr classification ALL_OF PII PCI PHI MNPI)"
map_value_to_depts "$(val_id "$CLS_JSON" mnpi)" Engineering HR Accounting Sales
map_value_to_depts "$(val_id "$CLS_JSON" pii)"  HR Accounting Sales
map_value_to_depts "$(val_id "$CLS_JSON" pci)"  Accounting
map_value_to_depts "$(val_id "$CLS_JSON" phi)"  HR
echo "Created classification (ALL_OF) + 4 subject mappings"

# --- Export --------------------------------------------------------------------
"$TRUCTL" --host "$HOST" --tls-no-verify --with-client-creds "$CLIENT_CREDS" \
  export -n "$NAMESPACE" --no-bundle -o "$EXPORT_FILE"
echo "Exported $NAMESPACE policy -> $EXPORT_FILE"
