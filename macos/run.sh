#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command="${1:-run}"
if (( $# )); then shift; fi

case "$command" in
  build) exec xcrun swift "$ROOT/build.swift" "$@" ;;
  run|check)
    app="${JOYSTREAM_MACOS_APP:-$ROOT/.build/JoystreamServer.app}"
    executable="$app/Contents/MacOS/JoystreamServer"
    if [[ ! -x "$executable" ]]; then
      echo 'Build the signed server first: ./macos/run.sh build --profile FILE --identity NAME' >&2
      echo 'See macos/README.md for the Virtual HID entitlement and Accessibility setup.' >&2
      exit 1
    fi
    if [[ "$command" == check ]]; then exec "$executable" --check "$@"; fi
    exec "$executable" "$@"
    ;;
  diagnostics)
    executable="$ROOT/.build/JoystreamServer-Diagnostics.app/Contents/MacOS/JoystreamServer"
    if [[ ! -x "$executable" ]]; then
      echo 'Build diagnostics first: ./macos/run.sh build --unsigned' >&2
      exit 1
    fi
    exec "$executable" --dry-run "$@"
    ;;
  help|--help|-h)
    echo 'Usage: ./macos/run.sh {build|run|check|diagnostics} [OPTIONS]'
    echo 'build: --profile FILE --identity NAME [--output PATH.app], or --unsigned'
    echo 'run/diagnostics: --host ADDRESS --port PORT (default 0.0.0.0:8000)'
    ;;
  *) echo "Unknown command: $command" >&2; exit 2 ;;
esac
