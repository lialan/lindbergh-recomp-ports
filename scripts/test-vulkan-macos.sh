#!/usr/bin/env bash
# Source-owned direct Vulkan checks on macOS through Mesa KosmicKrisp.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build-vulkan-macos}"
[ "$(uname -s)" = Darwin ] || { echo "macOS required" >&2; exit 1; }
# Never silently substitute a different driver for this acceptance path.
export VK_DRIVER_FILES="${VK_DRIVER_FILES:-/opt/homebrew/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json}"
[ -f "$VK_DRIVER_FILES" ] || { echo "KosmicKrisp ICD missing: $VK_DRIVER_FILES" >&2; exit 1; }
export VK_INSTANCE_LAYERS="${VK_INSTANCE_LAYERS:-VK_LAYER_KHRONOS_validation}"
printf 'Vulkan ICD: %s\n' "$VK_DRIVER_FILES"
cmake -S "$ROOT/lindberghrecomp/src/renderer/vulkan" -B "$BUILD" -G Ninja \
    -DBUILD_TESTING=ON -DLINDBERGH_VULKAN_SDL=ON
cmake --build "$BUILD" --target lindbergh_vulkan_selftest lindbergh_vulkan_window_test -j4
"$BUILD/lindbergh_vulkan_selftest"
"$BUILD/lindbergh_vulkan_window_test"
