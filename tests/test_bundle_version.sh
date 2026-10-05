#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Load the real function without running the stack setup in the rest of the script.
awk '
  /^ensure_bundle_directory_ready\(\) \{$/ { in_function = 1 }
  in_function { print }
  in_function && /^}$/ { exit }
' "$repo_dir/setup_and_validate.sh" > "$tmp_dir/function.sh"
source "$tmp_dir/function.sh"
declare -F ensure_bundle_directory_ready >/dev/null

log_ok() { :; }
log_fail() { :; }

cat > "$tmp_dir/dsp" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == version ]] || exit 2
printf 'Version: %s\n' "$TEST_DSP_VERSION"
exit "${TEST_DSP_EXIT:-0}"
EOF
chmod +x "$tmp_dir/dsp"

expect_version() {
  local reported="$1" expected="$2"
  TEST_DSP_VERSION="$reported" TEST_DSP_EXIT=0
  export TEST_DSP_VERSION TEST_DSP_EXIT
  DSP_PLATFORM_IMAGE_TAG="v0.0.0"
  ensure_bundle_directory_ready "$tmp_dir"
  [[ "$DSP_PLATFORM_IMAGE_TAG" == "$expected" ]] || {
    echo "Expected $expected, got $DSP_PLATFORM_IMAGE_TAG" >&2
    exit 1
  }
}

expect_invalid_version() {
  local reported="$1" exit_code="$2"
  TEST_DSP_VERSION="$reported" TEST_DSP_EXIT="$exit_code"
  export TEST_DSP_VERSION TEST_DSP_EXIT
  DSP_PLATFORM_IMAGE_TAG="v0.0.0"
  if ensure_bundle_directory_ready "$tmp_dir"; then
    echo "Unexpectedly accepted version '$reported'" >&2
    exit 1
  fi
  [[ "$DSP_PLATFORM_IMAGE_TAG" == "v0.0.0" ]] || {
    echo "Invalid version changed the image tag" >&2
    exit 1
  }
}

expect_version "v2.7.15" "v2.7.15"
expect_version "2.7.16" "v2.7.16"
expect_invalid_version "not-a-version" 0
expect_invalid_version "" 1
expect_invalid_version "v2.7.15" 1

echo "Bundle platform version tests passed"
