#!/usr/bin/env bash
# Compare the bundled federal sample with the policy objects returned by tructl.
# Usage: validate_federal_policy.sh SAMPLE ATTRIBUTES_JSON SUBJECTS_JSON RESOURCES_JSON
set -euo pipefail

[[ $# -eq 4 ]] || { echo "Usage: $0 SAMPLE ATTRIBUTES_JSON SUBJECTS_JSON RESOURCES_JSON" >&2; exit 2; }
sample=$1
attributes_file=$2
subjects_file=$3
resources_file=$4

jq -e '.attributes | type == "array"' "$attributes_file" >/dev/null
jq -e '.subject_mappings | type == "array"' "$subjects_file" >/dev/null
jq -e '.resource_mappings | type == "array"' "$resources_file" >/dev/null

# The sample is generated from the selected bundle. Read its values and mapping
# declarations so a later bundle does not silently keep this release's list.
expected_values=$(awk '
  /^attributes:/ { inside=1; next }
  /^obligations:/ { inside=0 }
  inside && /^      - name: / { name=$3 }
  inside && /^          - value: / {
    print "https://demo.com/attr/" name "/value/" tolower($3)
  }
' "$sample" | sort -u)
expected_subjects=$(awk '
  /^subject_mappings:/ { inside=1; next }
  /^subject_condition_sets:/ { inside=0 }
  inside && /^    attribute_value: demo.com\/attr\// { print "https://" $2 }
  inside && /^  sm_nationality_[A-Z]+:/ {
    code=$0
    sub(/^  sm_nationality_/, "", code)
    sub(/:.*/, "", code)
  }
  inside && /^    template: template_relto_one_nationality/ {
    print "https://demo.com/attr/relto/value/" tolower(code)
  }
' "$sample" | sort -u)
expected_links=$(awk '
  /^subject_mappings:/ { inside=1; next }
  /^subject_condition_sets:/ { inside=0 }
  inside && /^  sm_/ { fqn="" }
  inside && /^    attribute_value: demo.com\/attr\// { fqn="https://" $2 }
  inside && /^    subject_condition_set_name:/ && fqn != "" {
    print fqn "|" $2
  }
' "$sample")
condition_specs=$(awk '
  /^approved_clients:/ {
    clients=$0
    sub(/^.*\[/, "", clients)
    sub(/\].*$/, "", clients)
    n=split(clients, approved, ",")
    for (i=1; i<=n; i++) gsub(/^ +| +$/, "", approved[i])
  }
  /^subject_condition_sets:/ { inside=1; next }
  /^subject_mapping_templates:/ { inside=0 }
  inside && /^  scs_[^:]+:/ { set=$1; sub(/:$/, "", set) }
  inside && /^              - subject_external_selector_value:/ {
    selector=$3
    gsub(/\047/, "", selector)
  }
  inside && /^                subject_external_values: \*approved_clients/ {
    for (i=1; i<=n; i++) print set "|" selector "|" approved[i]
  }
  inside && /^                  - / {
    value=$0
    sub(/^                  - /, "", value)
    print set "|" selector "|" value
  }
' "$sample")
expected_explicit_conditions=$(awk -F'|' '
  NR == FNR { fqn[$2]=$1; next }
  $1 in fqn { print fqn[$1] "|" $2 "|" $3 }
' <(printf '%s\n' "$expected_links") <(printf '%s\n' "$condition_specs") | sort -u)
expected_template_conditions=$(awk '
  /^approved_clients:/ {
    clients=$0
    sub(/^.*\[/, "", clients)
    sub(/\].*$/, "", clients)
    n=split(clients, approved, ",")
    for (i=1; i<=n; i++) gsub(/^ +| +$/, "", approved[i])
  }
  /^subject_mappings:/ { inside=1; next }
  /^subject_condition_sets:/ { inside=0 }
  inside && /^  sm_nationality_[A-Z]+:/ {
    code=$0
    sub(/^  sm_nationality_/, "", code)
    sub(/:.*/, "", code)
  }
  inside && /^    template: template_relto_one_nationality/ {
    fqn="https://demo.com/attr/relto/value/" tolower(code)
    print fqn "|.attributes.nationality[]|" code
    for (i=1; i<=n; i++) print fqn "|.clientId|" approved[i]
  }
' "$sample" | sort -u)
expected_conditions=$(printf '%s\n%s\n' "$expected_explicit_conditions" "$expected_template_conditions" | sort -u)
expected_resource_terms=$(awk '
  /^resource_mappings:/ { inside=1; next }
  inside && /^    attribute_value: demo.com\/attr\// { fqn="https://" $2 }
  inside && /^      - / && fqn != "" { print fqn "|" $2 }
' "$sample" | sort -u)

# Fail closed if the sample layout changes beyond the declarations above.
[[ $(wc -l <<<"$expected_values") -eq 260 &&
   $(wc -l <<<"$expected_subjects") -eq 259 &&
   $(wc -l <<<"$expected_links") -eq 11 &&
   $(wc -l <<<"$expected_template_conditions") -eq 744 &&
   -n "$expected_explicit_conditions" &&
   $(wc -l <<<"$expected_resource_terms") -eq 9 ]] || {
  echo "Federal sample layout changed; update the exact policy validator" >&2
  exit 1
}

actual_values=$(jq -r '
  .attributes[] | select(.namespace.name == "demo.com") |
  .values[]? | select(.active.value != false) | .fqn
' "$attributes_file" | sort -u)
actual_subjects=$(jq -r '
  .subject_mappings[] |
  select(any(.actions[]?; .name == "read")) |
  select((.subject_condition_set.subject_sets // [] | length) > 0) |
  .attribute_value.fqn
' "$subjects_file" | sort -u)
actual_conditions=$(jq -r '
  .subject_mappings[] | . as $mapping |
  select(any(.actions[]?; .name == "read")) |
  .subject_condition_set.subject_sets[]?.condition_groups[]? |
  select(.boolean_operator == 2) | .conditions[]? |
  select(.operator == 1) |
  . as $condition | .subject_external_values[]? |
  "\($mapping.attribute_value.fqn)|\($condition.subject_external_selector_value)|\(.)"
' "$subjects_file" | sort -u)
actual_resource_terms=$(jq -r '
  .resource_mappings[] | .attribute_value.fqn as $fqn |
  .terms[]? | "\($fqn)|\(.)"
' "$resources_file" | sort -u)

missing=0
check_items() {
  local label=$1 expected=$2 actual=$3 item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    echo "Missing federal $label: $item" >&2
    missing=1
  done < <(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
}

check_items 'attribute value' "$expected_values" "$actual_values"
check_items 'subject mapping with read action' "$expected_subjects" "$actual_subjects"
check_items 'subject condition' "$expected_conditions" "$actual_conditions"
check_items 'resource mapping term' "$expected_resource_terms" "$actual_resource_terms"
exit "$missing"
