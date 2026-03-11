//: # Lesson 14: Cancellation Sensitivity — Not Every `await` Is a Cancellation Point
//:
//: Calling `.cancel()` sets a flag. Whether the task *notices* depends entirely
//: on what it is currently `await`-ing. Some suspension points check the flag
//: automatically; others ignore it completely.
//:
//: This page proves each case by cancelling after 200ms and observing the outcome.
//:
//: | Suspension point                  | Cancellation-sensitive? |
//: |-----------------------------------|-------------------------|
//: | `try await Task.sleep(...)`       | ✅ Yes — throws immediately     |
//: | `await task.value`                | ❌ No  — waits for inner task   |
//: | `try Task.checkCancellation()`    | ✅ Yes — at each check point    |
//: | `await actor.method()`            | ❌ No  — hop always completes   |

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - Helpers

func cancelAfter(_ ms: Int, task: Task<some Any, some Any>) {
    Task {
        try? await Task.sleep(for: .milliseconds(ms))
        task.cancel()
        print("  → cancel() called after \(ms)ms")
    }
}

// MARK: - Case 1: try await Task.sleep — sensitive ✅

func workWithSleep() async throws -> String {
    print("  [sleep] started, sleeping 600ms...")
    try await Task.sleep(for: .milliseconds(600)) // throws CancellationError if cancelled
    print("  [sleep] completed ✓")
    return "done"
}

// MARK: - Case 2: await task.value — NOT sensitive ❌

func workWithTaskValue() async throws -> String {
    let inner = Task {
        print("  [task.value] inner task sleeping 600ms...")
        try? await Task.sleep(for: .milliseconds(600))
        print("  [task.value] inner task completed ✓")
        return "done"
    }
    // Even if THIS task is cancelled, this await does not throw or exit early.
    // It waits for inner to finish regardless.
    return try await inner.value
}

// MARK: - Case 3: Task.checkCancellation() in a CPU loop — sensitive at check points ✅

func workWithCheckCancellation() async throws -> Int {
    var count = 0
    print("  [checkCancellation] started CPU loop...")
    for i in 0..<10_000_000 {
        // Only notices cancellation every 100_000 iterations — granularity matters
        if i % 100_000 == 0 {
            try Task.checkCancellation()
        }
        count += 1
    }
    print("  [checkCancellation] completed ✓")
    return count
}

// MARK: - Demo

Task {
    // ── Case 1: Task.sleep ───────────────────────────────────────────────────
    print("=== Case 1: try await Task.sleep — cancel after 200ms ===\n")

    let t1 = Task { try await workWithSleep() }
    cancelAfter(200, task: t1)

    do {
        _ = try await t1.value
        print("  Result: returned normally\n")
    } catch is CancellationError {
        print("  Result: CancellationError ✅ — sleep threw immediately\n")
    }

    try await Task.sleep(for: .milliseconds(200))

    // ── Case 2: task.value ───────────────────────────────────────────────────
    print("\n=== Case 2: await task.value — cancel after 200ms ===\n")

    let t2 = Task { try await workWithTaskValue() }
    cancelAfter(200, task: t2)

    do {
        _ = try await t2.value
        print("  Result: returned normally ❌ — cancel() had no effect, waited full 600ms\n")
    } catch is CancellationError {
        print("  Result: CancellationError\n")
    }

    try await Task.sleep(for: .milliseconds(200))

    // ── Case 3: checkCancellation in CPU loop ────────────────────────────────
    print("\n=== Case 3: Task.checkCancellation() in loop — cancel after 200ms ===\n")

    let t3 = Task { try await workWithCheckCancellation() }
    cancelAfter(200, task: t3)

    do {
        let n = try await t3.value
        print("  Result: completed with count=\(n) (finished before cancel)\n")
    } catch is CancellationError {
        print("  Result: CancellationError ✅ — noticed at next checkCancellation() call\n")
    }

    try await Task.sleep(for: .milliseconds(200))

    print("""
    Summary:
    • try await Task.sleep      ✅ sensitive  — throws CancellationError immediately
    • await task.value          ❌ insensitive — waits for inner task regardless
    • Task.checkCancellation()  ✅ sensitive  — but only as granular as your check frequency
    """)

    PlaygroundPage.current.finishExecution()
}
