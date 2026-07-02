# Native-addon repo (N-API binding)

Applies to repos that ship a Node.js native addon — a TypeScript layer over a C++ N-API binding built with node-gyp. First consumer: `@harperfast/rocksdb-js` (`src/*.ts` over `src/binding/*.cpp|h`, C++20, prebuilt RocksDB libs). These repos have a review surface that pure-TS layers never exercise: memory ownership across the JS/C++ boundary, thread affinity, and native resource lifecycle. This is Harper's storage hot path — defects here are data-loss or process-crash class, not exceptions.

## The sync/Promise contract (`MaybePromise`)

- The addon's signature design pattern: operations return a **value synchronously when served from cache and a Promise on a miss** (hybrid sync/async). This contract is load-bearing for downstream consumers — an unguarded synchronous consumer misclassified a valid cursor and deleted it from disk (harper-pro#487, data-loss, human-corroborated).
- Treat ANY change to *which paths return sync vs Promise* as a **breaking public API change**: it silently breaks every consumer that pattern-matched the old behavior. Flag it as a blocker unless the PR explicitly documents the contract change and versions it accordingly.
- New APIs must document their sync/Promise behavior; a doc that says "returns X" for a MaybePromise API is integrator-misleading.

## JS/C++ boundary (memory + lifetime)

- **Ownership of every buffer crossing the boundary.** An external/zero-copy buffer pointing into C++-owned memory (a RocksDB slice, a pinned block) must not outlive the native object that owns it — check what happens when JS retains the buffer after the iterator/transaction/DB closes. Copy-vs-borrow must be deliberate and stated.
- **Finalizer vs explicit close.** Handles typically support both explicit `close()` and GC finalization. Verify double-free safety (explicit close then GC finalizer firing later) and that the finalizer path frees everything the close path does — a leak that only manifests under GC pressure won't show in happy-path tests.
- **No V8/N-API calls off the main thread.** Work running on a RocksDB/background thread must marshal back via a thread-safe function before touching JS values. Verify TSFN lifetime: released exactly once, and never called after release (crash on shutdown paths).
- **C++ exceptions must not cross the N-API boundary**; `rocksdb::Status` must be checked and mapped to a JS error on every path — a dropped Status silently swallows corruption/IO errors.

## Native resource lifecycle and threading

- **Close ordering is a hard invariant**: iterators, transactions, snapshots, and log readers must be released before the owning DB handle closes. The registry pattern (`db_registry`, `*_handle` classes, mutex-guarded stores) exists to enforce this — verify new resource types register/unregister symmetrically, including on the **error and abort branches** (the universal error/abort rule applies doubly here: a leaked native handle pins memory *and* can deadlock or crash close).
- **Lock discipline.** The binding uses `std::mutex`/`lock_guard` heavily (registries, transaction-log stores). Check new/moved locking for: lock held across a callback into JS (deadlock), lock ordering between registries (ABBA), and state read outside the lock that is written inside it.
- **Event-loop blocking.** A synchronous native call that can do disk I/O or large decode on the JS thread is a hot-path perf finding — this library sits under every Harper read/write.

## Platform divergence

- Platform-split implementations exist (e.g. `transaction_log_file_posix.cpp` / `transaction_log_file_windows.cpp`). A fix to one side is presumed incomplete until the PR states why the other side doesn't need it — flag the silent half-fix.

## Build, ABI, and runtime matrix

- `binding.gyp` / prebuilt-library changes: verify the compile-flag or link change is reflected for all target platforms, and that `engines.node` still matches the N-API/ABI floor the code assumes (currently `^22.18.0 || >=24.0.0`).
- The test suite runs on **Node, Bun, and Deno** (`pnpm test`, `test:bun`, `test:deno`). A change relying on Node-only behavior in the TS layer needs a stated reason, since CI exercises all three.
- New runtime deps: same minimal-deps bar as other Harper repos (current runtime deps: `msgpackr`, `ordered-binary`, `@harperfast/extended-iterable`).

## Tests for native changes

- Lifecycle/concurrency changes need coverage in the **stress suite** (`pnpm test:stress`) or a GC-exercising test (`node --expose-gc … vitest …`), not just happy-path vitest — races and finalizer bugs don't reproduce in unit tests.
- Encoding changes (ordered-binary keys, msgpack values) need round-trip tests including boundary values (empty keys, max-length, negative/float ordering) — key-order regressions corrupt range queries silently.
- Perf-sensitive paths (get/put/iterator/commit): if the PR claims a perf motive, expect a benchmark delta (`pnpm bench`); if it touches those paths without one, a hot-path regression check is a fair non-blocking suggestion.
