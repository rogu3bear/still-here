# The standalone website template remains usable without the native checkout.
# In this repository, all website and native build scripts share one owner.
BUILD_SUPPORT_PARENT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "$BUILD_SUPPORT_PARENT/Package.swift" && -f "$BUILD_SUPPORT_PARENT/scripts/build.py" ]]; then
  source "$BUILD_SUPPORT_PARENT/scripts/build-support.sh"
fi
