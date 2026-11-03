#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
developer_path="${DEVELOPER_DIR:-$(xcode-select -p)}"
swift test --disable-sandbox --disable-xctest --enable-swift-testing --scratch-path .build \
  --cache-path .build/cache --config-path .build/config --security-path .build/security \
  -Xswiftc -F -Xswiftc "$developer_path/Library/Developer/Frameworks" "$@"
