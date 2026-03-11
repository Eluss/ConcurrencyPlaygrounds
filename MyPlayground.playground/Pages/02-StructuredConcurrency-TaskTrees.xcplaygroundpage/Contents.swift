//: # Lesson 2: Structured Concurrency & Task Trees
//:
//: **The nuance:** Cancellation is cooperative AND only delivered at
//: *cancellation-sensitive* suspension points. Not every `await` is one.
//:
//: - `try await Task.sleep(...)` → cancellation-sensitive, throws immediately
//: - `await someTask.value`      → NOT cancellation-sensitive, waits for the task regardless
//:
//: This means: if a cancelled task is stuck waiting on an unstructured `Task { }`,
//: it will NOT be interrupted. It waits, the inner task finishes, and the outer
//: task may return a normal result — as if cancel() was never called.
//:
//: Structured concurrency (`async let`, `TaskGroup`) sidesteps this entirely:
//: cancelling the parent propagates into children, which DO hit cancellation-sensitive
//: points (sleep, network calls), and unwind immediately.
//:
//: **Real scenario:** User navigates away from a search screen.
//: We cancel the search task — does work actually stop?

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// #Interesting

struct SearchResult { let source: String }

// MARK: - Simulated fetches — Task.sleep IS cancellation-sensitive

func searchDatabase(_ query: String) async throws -> SearchResult {
    print("  [DB]    started")
    try await Task.sleep(for: .milliseconds(400))  // throws if THIS task is cancelled
    print("  [DB]    completed ✓")
    return SearchResult(source: "Database")
}

func searchAPI(_ query: String) async throws -> SearchResult {
    print("  [API]   started")
    try await Task.sleep(for: .milliseconds(600))
    print("  [API]   completed ✓")
    return SearchResult(source: "REST API")
}

// MARK: - ✅ Structured: async let makes DB/API child tasks of the calling task

func performSearch(query: String) async throws -> [SearchResult] {
    async let db    = searchDatabase(query)
    async let api   = searchAPI(query)
    // Cancelling the task running performSearch() → db and api tasks cancelled too
    return try await [db, api]
}

// MARK: - ❌ Unstructured: inner Task { } instances are independent, not children

func performSearchUnstructured(query: String) async throws -> [SearchResult] {
    let dbTask  = Task { try await searchDatabase(query) }
    let apiTask = Task { try await searchAPI(query) }

    // `await task.value` is NOT cancellation-sensitive.
    // Even if the task running this function is cancelled, these awaits do NOT throw.
    // They wait for dbTask/apiTask to finish normally.
    return try await [dbTask.value, apiTask.value]
}

// MARK: - ✅ Unstructured with cancellation: manually bridge via withTaskCancellationHandler

func performSearchUnstructuredCancellable(query: String) async throws -> [SearchResult] {
    let dbTask  = Task { try await searchDatabase(query) }
    let apiTask = Task { try await searchAPI(query) }

    return try await withTaskCancellationHandler {
        return try await [dbTask.value, apiTask.value]
    } onCancel: {
        // Runs synchronously when the outer task is cancelled.
        // Propagates cancellation into the inner tasks — they hit Task.sleep and throw.
        dbTask.cancel()
        apiTask.cancel()
    }
}

// MARK: - Demo

Task {
    // ── Structured ──────────────────────────────────────────────────────────
    print("=== Structured (async let) — cancel after 200ms ===\n")

    let structuredTask = Task { try await performSearch(query: "q") }
    try await Task.sleep(for: .milliseconds(200))
    print("→ cancel() called\n")
    structuredTask.cancel()

    do {
        _ = try await structuredTask.value
        print("Returned normally")
    } catch is CancellationError {
        print("→ CancellationError ✓  (children hit Task.sleep and threw)\n")
    }

    // Give any possible leaked work time to surface
    try await Task.sleep(for: .milliseconds(600))
    print("(silence above = no leaked work)\n\n")

    // ── Unstructured ─────────────────────────────────────────────────────────
    print("=== Unstructured (Task {}) — cancel after 200ms ===\n")

    let unstructuredTask = Task { try await performSearchUnstructured(query: "q") }
    try await Task.sleep(for: .milliseconds(200))
    print("→ cancel() called\n")
    unstructuredTask.cancel()

    do {
        let results = try await unstructuredTask.value
        // ⚠️ We get here — no error!
        // cancel() set the flag on unstructuredTask, but it was parked at
        // `await dbTask.value` which is NOT cancellation-sensitive.
        // Both inner tasks ran to completion and returned normally.
        print("→ Returned normally with \(results.count) results — cancel() had NO effect!")
    } catch is CancellationError {
        print("→ CancellationError")
    }

    try await Task.sleep(for: .milliseconds(600))
    print("(inner tasks above completed despite cancel)\n\n")

    // ── Unstructured with cancellation support ────────────────────────────────
    print("=== Unstructured + withTaskCancellationHandler — cancel after 200ms ===\n")

    let cancellableTask = Task { try await performSearchUnstructuredCancellable(query: "q") }
    try await Task.sleep(for: .milliseconds(200))
    print("→ cancel() called\n")
    cancellableTask.cancel()

    do {
        _ = try await cancellableTask.value
        print("→ Returned normally")
    } catch is CancellationError {
        print("→ CancellationError ✓  (onCancel forwarded cancel to inner tasks)\n")
    }

    try await Task.sleep(for: .milliseconds(600))
    print("(silence above = no leaked work)\n")

    print("""

    Key insights:
    • `await task.value` is NOT cancellation-sensitive — it ignores the calling
      task's cancellation flag and waits for the inner task to finish.
    • `try await Task.sleep(...)` IS cancellation-sensitive — it throws immediately.
    • Structured concurrency (async let / TaskGroup) propagates cancellation into
      children automatically — they hit Task.sleep and unwind quickly.
    • Unstructured Task { } creates siblings — cancelling the outer task does
      not touch them, and awaiting their .value doesn't respond to cancellation.
    • Fix while keeping Task {}: wrap the awaits in withTaskCancellationHandler
      and manually cancel inner tasks in onCancel — bridges the gap explicitly.
    """)

    PlaygroundPage.current.finishExecution()
}
