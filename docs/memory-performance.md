# Thumbnails stay within a decoded-image budget

The previous shared NSCache had a 400 MiB soft cost limit. The cache now evicts the least recently used images before
crossing 128 MiB or 1,500 entries, and clears on memory-pressure warnings. Visible views retain their own images;
evicting a cache entry does not remove an image from the screen. Quick Look size/scale buckets, request coalescing,
cancellation and image quality stay the same. A cropped image is charged for its original decoded backing.

Run `scripts/benchmark-memory.sh thumbnails-baseline 160` and `scripts/benchmark-memory.sh thumbnails 160`.
The baseline reproduces main 8cad325's NSCache policy. Both runs generate the same 160 distinct, heap-backed,
1024 × 1024 RGBA thumbnails (4 MiB each) without retaining them outside the cache. They use the app's default actor
isolation. These workloads measure decoded image retention, not Quick Look generation or whole-app memory.

| 160 generated Retina thumbnails | Before | After |
| --- | ---: | ---: |
| Images retained | 100 | 32 |
| Process footprint increase | 408.64 MiB | 135.41 MiB |
| Time to generate and cache all images | 276 ms | 285 ms |

The measured reduction is **273.23 MiB (66.9%)** for this cache-filling workload. Before/after footprint increases
varied by less than 0.04 MiB across three runs. A smaller cache can regenerate more thumbnails when revisiting older
folders; it does not reduce thumbnail resolution. The fill-time ranges overlap (272–322 ms before, 282–314 ms after).

Validation: deterministic eviction and recency, replacements, oversized entries, count limit, releasing offscreen
images while visible images remain usable, coalesced requests, last-reader cancellation, ignoring stale completions,
regeneration with identical pixels, fallback size buckets, changed files, failed/cancelled requests and cropped backing
cost.

## Switching away from a large listing

Icons and Gallery retain selected URLs and a scroll anchor when detached. They rebuild their rows and path lookup
from the browser's current listing when shown again. The thumbnail cache also removes path lookups as it evicts images.

Run the opt-in measurement in a fresh test process:

```sh
STRATA_BROWSER_BENCHMARK=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter measureHiddenListing
```

The offscreen browser shows 100,000 synthetic folder results, switches through Icons, Gallery and List, then replaces
the results with one entry. The synthetic URLs require no server. Across three independent debug processes per version,
median physical footprint after settling fell from 134.5 MiB to 56.9 MiB. Both detached presentations previously kept
100,000 entries each and now keep zero. This workload measures retained listing memory after switching views.
