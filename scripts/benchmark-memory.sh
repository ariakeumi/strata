#!/usr/bin/env bash
# Compares thumbnail caches with generated images.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
memory_benchmark_dir=$(mktemp -d "${TMPDIR:-/tmp}/strata-memory-benchmark.XXXXXX")
trap 'rm -rf "$memory_benchmark_dir"' EXIT
xcrun swiftc -O -swift-version 6 -parse-as-library -package-name Strata \
  -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -module-cache-path "$memory_benchmark_dir/modules" \
  Sources/Strata/Views/ThumbnailCache.swift \
  Tests/Benchmarks/ThumbnailCacheBaseline.swift Tests/Benchmarks/MemoryBenchmark.swift \
  -o "$memory_benchmark_dir/benchmark"
for memory_benchmark_run in 1 2 3; do
  "$memory_benchmark_dir/benchmark" "$@"
done
