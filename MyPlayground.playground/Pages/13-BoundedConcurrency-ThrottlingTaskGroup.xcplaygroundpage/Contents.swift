//: # Lesson 13: Bounded Concurrency — Throttling a `TaskGroup`
//:
//: **The nuance:** `withTaskGroup` fans out ALL `addTask` calls immediately.
//: For 200 files, that's 200 concurrent tasks — which can overwhelm servers,
//: exhaust file descriptors, or trigger rate-limiting (HTTP 429).
//:
//: The fix is the *sliding window* pattern:
//: 1. Seed the group with exactly `maxConcurrency` tasks.
//: 2. Each time a task completes (via `for await`), add the next one.
//: This keeps exactly N tasks in flight at all times.
//:
//: **A subtler variant:** collect results in submission order (not completion order)
//: using an indexed result type — important when callers expect ordered output.
//:
//: **Real scenario:** Syncing 200 user photos to a CDN that enforces
//: a 5-connection limit per client. Fan-out must be throttled.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - Simulated upload

struct UploadResult { let id: Int; let durationMs: Int }

var activeUploads = 0  // track concurrency to verify the cap
var peakConcurrency = 0

func upload(id: Int) async throws -> UploadResult {
    activeUploads += 1
    peakConcurrency = max(peakConcurrency, activeUploads)
    let ms = Int.random(in: 80...300)
    try await Task.sleep(for: .milliseconds(ms))
    activeUploads -= 1
    print("  ✓ file-\(String(format: "%02d", id)) (\(ms)ms) — \(activeUploads) still in flight")
    return UploadResult(id: id, durationMs: ms)
}

// MARK: - ❌ Unbounded: all N tasks start at once

func uploadUnbounded(ids: [Int]) async throws -> [UploadResult] {
    try await withThrowingTaskGroup(of: UploadResult.self) { group in
        for id in ids { group.addTask { try await upload(id: id) } }
        var results: [UploadResult] = []
        for try await result in group { results.append(result) }
        return results
    }
}

// MARK: - ✅ Bounded: sliding window keeps exactly `maxConcurrency` tasks in flight

func uploadBounded(ids: [Int], maxConcurrency: Int) async throws -> [UploadResult] {
    try await withThrowingTaskGroup(of: UploadResult.self) { group in
        var iterator = ids.makeIterator()
        var results: [UploadResult] = []

        // Seed phase: fill the window
        for _ in 0..<min(maxConcurrency, ids.count) {
            if let id = iterator.next() {
                group.addTask { try await upload(id: id) }
            }
        }

        // Drain phase: as each task finishes, slot in the next item
        for try await result in group {
            results.append(result)
            if let next = iterator.next() {
                group.addTask { try await upload(next) }
                // Window size stays constant: one finished, one added
            }
        }

        return results
    }
}

// MARK: - ✅ Bonus: bounded AND results in submission order

// Sometimes callers need results in the original order (e.g., building a table view).
// Tag each result with its submission index, then sort at the end.
func uploadBoundedOrdered(ids: [Int], maxConcurrency: Int) async throws -> [UploadResult] {
    typealias Indexed = (index: Int, result: UploadResult)

    let ordered = try await withThrowingTaskGroup(of: Indexed.self) { group in
        var iterator = ids.enumerated().makeIterator()
        var indexed: [Indexed] = []

        for _ in 0..<min(maxConcurrency, ids.count) {
            if let (i, id) = iterator.next() {
                group.addTask { (i, try await upload(id: id)) }
            }
        }

        for try await item in group {
            indexed.append(item)
            if let (i, id) = iterator.next() {
                group.addTask { (i, try await upload(id: id)) }
            }
        }

        return indexed.sorted { $0.index < $1.index }.map(\.result)
    }
    return ordered
}

// MARK: - Demo

Task {
    let fileIds = Array(1...10)

    // ── Unbounded ────────────────────────────────────────────────────────────
    print("=== Unbounded (\(fileIds.count) tasks start simultaneously) ===\n")
    peakConcurrency = 0; activeUploads = 0
    let t1 = Date()
    _ = try! await uploadUnbounded(ids: fileIds)
    let elapsed1 = Date().timeIntervalSince(t1)
    print("\nUnbounded — peak concurrency: \(peakConcurrency)/\(fileIds.count), elapsed: \(String(format: "%.2fs", elapsed1))\n")

    // ── Bounded (max 3) ──────────────────────────────────────────────────────
    print("\n=== Bounded (max 3 concurrent) ===\n")
    peakConcurrency = 0; activeUploads = 0
    let t2 = Date()
    _ = try! await uploadBounded(ids: fileIds, maxConcurrency: 3)
    let elapsed2 = Date().timeIntervalSince(t2)
    print("\nBounded — peak concurrency: \(peakConcurrency)/3, elapsed: \(String(format: "%.2fs", elapsed2))\n")

    // ── Bounded + ordered ────────────────────────────────────────────────────
    print("\n=== Bounded + ordered output ===\n")
    peakConcurrency = 0; activeUploads = 0
    let ordered = try! await uploadBoundedOrdered(ids: fileIds, maxConcurrency: 3)
    print("\nOutput order: \(ordered.map(\.id))")
    print("(completion order differs, but results are sorted by submission index)\n")

    print("""
    Key insights:
    • withTaskGroup fans out ALL addTask calls immediately — no built-in throttle.
    • Sliding window pattern:
        1. Seed the group with min(maxConcurrency, total) tasks.
        2. For each completion, add the next item — window stays full.
    • maxConcurrency = 1 gives sequential execution with structured error handling.
      Useful when order matters and you still want cancellation/cleanup guarantees.
    • Results arrive in COMPLETION order by default. Tag with submission index
      and sort if callers require submission order.
    • Bounded concurrency trades total elapsed time for stability:
      fewer connections, less memory pressure, no rate-limit errors.
    """)

    PlaygroundPage.current.finishExecution()
}
