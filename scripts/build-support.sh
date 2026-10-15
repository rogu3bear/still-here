# Source from repository build scripts before they mutate shared output.
# Python 3.11+ owns the kernel lock; nested scripts inherit and validate it.
BUILD_SUPPORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  printf 'BUILD HOLD: Python 3.11 or later is required for build maintenance.\n' >&2
  exit 75
fi
if [[ -n "${STILLHERE_BUILD_LEASE:-}" ]]; then
  python3 -B "$BUILD_SUPPORT_ROOT/scripts/build.py" check-lease || exit $?
else
  exec python3 -B "$BUILD_SUPPORT_ROOT/scripts/build.py" exec -- bash "$0" "$@"
fi
