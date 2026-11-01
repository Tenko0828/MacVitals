#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/macvitals-checks.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT INT TERM
export CLANG_MODULE_CACHE_PATH="$task_tmp/clang-cache"
xcrun clang -fblocks -O2 -mmacosx-version-min=14.0 -I Sources/CVitalsSupport/include -c Sources/CVitalsSupport/Native.c -o "$task_tmp/Native.o"
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$task_tmp/swift-cache" -I Sources/CVitalsSupport/include Sources/VitalsCore/*.swift scripts/backend-checks.swift "$task_tmp/Native.o" -framework IOKit -framework SystemConfiguration -o "$task_tmp/backend-checks"
"$task_tmp/backend-checks"
