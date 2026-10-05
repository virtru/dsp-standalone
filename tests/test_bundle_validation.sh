#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Exercise the setup script's function without starting the DSP stack.
awk '
  /^ensure_bundle_directory_ready\(\) \{$/ { in_function = 1 }
  in_function { print }
  in_function && /^}$/ { exit }
' "$repo_dir/setup_and_validate.sh" > "$tmp_dir/function.sh"
source "$tmp_dir/function.sh"
declare -F ensure_bundle_directory_ready >/dev/null

log_ok() { :; }
log_fail() { :; }
DSP_PLATFORM_IMAGE_TAG="v2.7.14"
DSP_BUNDLE_RELEASE="2.0.6.6"

cat > "$tmp_dir/dsp" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == version ]] || exit 2
printf 'Version: %s\n' "$TEST_DSP_VERSION"
EOF
chmod +x "$tmp_dir/dsp"

for version in v2.7.14 2.7.14; do
  export TEST_DSP_VERSION="$version"
  ensure_bundle_directory_ready "$tmp_dir" || {
    echo "Rejected valid bundle version $version" >&2
    exit 1
  }
  [[ "$DSP_PLATFORM_IMAGE_TAG" == "v2.7.14" ]] || {
    echo "Unexpected image tag $DSP_PLATFORM_IMAGE_TAG" >&2
    exit 1
  }
done

for version in v2.7.15 not-a-version; do
  export TEST_DSP_VERSION="$version"
  if ensure_bundle_directory_ready "$tmp_dir"; then
    echo "Accepted invalid bundle version $version" >&2
    exit 1
  fi
done

echo "Bundle validation tests passed"
