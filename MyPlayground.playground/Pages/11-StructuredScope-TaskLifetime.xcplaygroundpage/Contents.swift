//: # Lesson 11: Structured Scope — Tasks Cannot Outlive Their Creator
//:
//: **The fundamental contract:** In structured concurrency, a child task is
//: *guaranteed* to finish before its parent scope exits. The compiler enforces this:
//: `async let` introduces a child task, and the scope's closing brace implicitly
//: awaits it. `withTaskGroup` does the same for every task added to the group.
//:
//: Unstructured `Task { }` has no such guarantee. It is a *peer* task —
//: it keeps running after the function that created it returns, indefinitely.
//:
//: **Why it matters:** Leaked unstructured tasks can:
//: - Hold references to objects that have been deallocated (crashes)
//: - Write to state after the owning context has been torn down (corruption)
//: - Perform network/disk work nobody is listening to (wasted resources)
//:
//: **Real scenario:** A search screen fires a task on every keystroke.
//: If those tasks are unstructured, typing "swift" launches 5 tasks.
//: After the user navigates away, all 5 keep running and may update
//: UI that no longer exists.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - Simulated work

func fetchResults(query: String, durationMs: Int) async -> String {
    print("  [\(query)] started")
    try? await Task.sleep(for: .milliseconds(durationMs))
    let cancelled = Task.isCancelled ? " — task was already cancelled, but still ran to completion" : ""
    print("  [\(query)] finished\(cancelled)")
    return "results for \(query)"
}

// MARK: - ❌ Unstructured: tasks outlive their creator

// Returns immediately. The task it fires keeps running.
// The caller has no handle and no way to cancel or await it.
func searchUnstructured(query: String) {
    Task {
        _ = await fetchResults(query: query, durationMs: 500)
    }
    // This print runs BEFORE the task above even starts
    print("  searchUnstructured('\(query)') returned — task is still running in the background")
}

// MARK: - ✅ Structured: the scope's closing brace awaits the child task

// Cannot return until the `async let` child task finishes.
// The compiler makes `async let` awaiting at scope exit mandatory — you cannot forget it.
func searchStructured(query: String) async {
    async let result = fetchResults(query: query, durationMs: 300)
    print("  searchStructured('\(query)') — scope will not exit until child task finishes")
    _ = await result
    // ← child task is guaranteed done by the time we reach this line
    print("  searchStructured('\(query)') returning — child task is done ✓")
}

// MARK: - ✅ Structured with TaskGroup: same guarantee, dynamic number of tasks

func searchAllStructured(queries: [String]) async {
    await withTaskGroup(of: String.self) { group in
        for query in queries {
            group.addTask { await fetchResults(query: query, durationMs: .random(in: 100...400)) }
        }
        // All tasks are guaranteed to complete before withTaskGroup returns,
        // even if we don't iterate the group — the group awaits stragglers on exit.
        for await result in group {
            print("  collected: \(result)")
        }
    }
    print("  searchAllStructured() returning — all \(queries.count) child tasks are done ✓")
}

// MARK: - Demo

Task {
    // ── Unstructured ─────────────────────────────────────────────────────────
    print("=== Unstructured: fire-and-forget ===\n")

    searchUnstructured(query: "actors")
    searchUnstructured(query: "sendable")
    print("\n  Both callers returned. Tasks are still running.\n")

    // Wait to let the leaked tasks surface in the log
    try? await Task.sleep(for: .milliseconds(700))

    // ── Structured: async let ─────────────────────────────────────────────────
    print("\n=== Structured: async let ===\n")
    await searchStructured(query: "swift concurrency")
    print("  Caller continues here — no leaks, no surprises.\n")

    // ── Structured: TaskGroup ─────────────────────────────────────────────────
    print("\n=== Structured: withTaskGroup (dynamic fan-out) ===\n")
    await searchAllStructured(queries: ["async let", "task group", "actor"])
    print()

    print("""
    Key insights:
    • async let / withTaskGroup: child tasks CANNOT outlive the scope.
      The compiler refuses to let the scope exit while a child task is still pending.
    • Task { }: peer task — fire-and-forget. No parent-child relationship.
      The caller gets back immediately; the task runs independently.
    • Leaked tasks are the concurrency equivalent of a memory leak:
      silent, hard to debug, and cumulative.
    • Rule of thumb: prefer structured unless you explicitly need fire-and-forget
      AND you store the returned Task handle to cancel it when appropriate.
    """)

    PlaygroundPage.current.finishExecution()
}
