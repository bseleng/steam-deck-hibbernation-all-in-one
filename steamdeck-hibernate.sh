#!/usr/bin/env bash
# Public entry point. Keep the three scripts together when copying to a Deck.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
case "${1:-}" in
  apply|install|reapply) shift ;;
  check|status|self-test|check-prereqs)
    shift
    set -- --check "$@"
    ;;
  uninstall|fix-swapfile|test-hibernate|test-suspend|enable-sth|disable-sth)
    printf '%s\n' "This legacy command is not supported by the safe reconciler." \
      "Use --help. Choose automatic suspend-then-hibernate with --enable-sth or --no-sth." >&2
    exit 2
    ;;
esac
exec bash "${SCRIPT_DIR}/steamdeck-hibernate-apply.sh" "$@"
