#!/bin/sh
# Use the provisioning commands supported by this DSP executable. Host tools
# and container images in a bundle can expose different command layouts.
set -eu

dsp_cli=${DSP_CLI:-/usr/bin/dsp}
operation=${1:-}
case "$operation" in
  policy|keycloak-from-config) shift ;;
  *) echo "Usage: $0 {policy|keycloak-from-config} [flags]" >&2; exit 2 ;;
esac

# Check the actual subcommand usage: deprecated stubs can return success for
# --help without implementing provisioning. Never retry a failed write using
# another command, since provisioning may already have created some objects.
if help_output=$("$dsp_cli" dev provision "$operation" --help 2>&1); then
  case "$help_output" in
    *" dev provision $operation [flags]"*)
      exec "$dsp_cli" dev provision "$operation" "$@"
      ;;
  esac
fi

if help_output=$("$dsp_cli" tructl provision "$operation" --help 2>&1); then
  case "$help_output" in
    # Legacy DSP registers Keycloak at both levels, but its help prints the
    # top-level path. Match the leaf usage, which a deprecated stub lacks.
    *" $operation [flags]"*)
      exec "$dsp_cli" tructl provision "$operation" "$@"
      ;;
  esac
fi

echo "FATAL: $dsp_cli does not support provisioning $operation via dsp dev or dsp tructl." >&2
exit 1
