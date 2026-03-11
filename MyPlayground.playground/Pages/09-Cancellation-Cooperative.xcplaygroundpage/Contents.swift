//: # Lesson 9: Cancellation — It's Cooperative, Not Preemptive
//:
//: **The nuance:** Calling `.cancel()` on a Task does NOT stop it immediately.
//: It sets a flag. The task must *check* that flag to actually stop.
//: Swift's async sleep/network calls check it automatically, but YOUR code doesn't.
//: Long CPU-bound loops will run to completion unless you add explicit checks.
//:
//: Three tools for cooperative cancellation:
//: - `Task.isCancelled` — check and decide what to do
//: - `try Task.checkCancellation()` — check and throw `CancellationError` automatically
//: - `withTaskCancellationHandler` — run cleanup code synchronously when cancelled
//:
//: **Real scenario:** A background document indexer that must stop promptly
//: when the user closes the document, without corrupting the index.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - ❌ Non-cooperative: ignores cancellation, runs to completion

func indexDocumentsNaive(count: Int) async -> Int {
    var indexed = 0
    for i in 0..<count {
        indexed += i.description.count // CPU work — no suspension point, no cancellation check
    }
    return indexed
}

// MARK: - ✅ Cooperative: checks cancellation periodically

func indexDocumentsCooperative(count: Int) async throws -> Int {
    var indexed = 0
    for i in 0..<count {
        // Check every 500 iterations — balance between responsiveness and overhead
        if i % 500 == 0 {
            try Task.checkCancellation() // throws CancellationError if cancelled
        }
        indexed += i.description.count
    }
    return indexed
}

// MARK: - withTaskCancellationHandler: synchronous cleanup on cancellation

func indexWithCleanup(count: Int) async throws -> Int {
    return try await withTaskCancellationHandler {
        // This block runs the actual work
        var indexed = 0
        for i in 0..<count {
            if i % 500 == 0 { try Task.checkCancellation() }
            indexed += i.description.count
        }
        return indexed
    } onCancel: {
        // This closure runs SYNCHRONOUSLY on the cancelling thread when cancel() is called
        // Use it to: invalidate timers, cancel URLSession tasks, close file handles
        print("  → onCancel fired synchronously — releasing resources")
    }
}

// MARK: - AsyncStream with onTermination for cleanup

func documentStream(count: Int) -> AsyncStream<String> {
    AsyncStream { continuation in
        // nonisolated(unsafe): safe here because onTermination writes once
        // before the Task loop can observe it, and there's no concurrent mutation.
        nonisolated(unsafe) var resourceOpen = true
        print("  [stream] resource acquired")

        continuation.onTermination = { reason in
            // Called when: stream finishes, or consumer breaks/cancels
            resourceOpen = false
            print("  [stream] resource released (reason: \(reason))")
        }

        Task {
            for i in 0..<count {
                try? await Task.sleep(for: .milliseconds(100))
                guard resourceOpen else { break }
                continuation.yield("document-\(i)")
            }
            continuation.finish()
        }
    }
}

// MARK: - Demo

Task {
    print("=== Demo 1: cooperative cancellation in CPU loop ===\n")

    let indexTask = Task {
        try await indexDocumentsCooperative(count: 100_000)
    }

    try await Task.sleep(for: .milliseconds(5))
    indexTask.cancel()

    do {
        let result = try await indexTask.value
        print("Indexed: \(result) chars (completed before cancel)")
    } catch is CancellationError {
        print("Indexing cancelled ✓")
    }

    print("\n=== Demo 2: withTaskCancellationHandler ===\n")

    let cleanTask = Task {
        try await indexWithCleanup(count: 100_000)
    }

    try await Task.sleep(for: .milliseconds(5))
    cleanTask.cancel()

    do {
        _ = try await cleanTask.value
    } catch is CancellationError {
        print("Task cancelled with cleanup ✓")
    }

    print("\n=== Demo 3: AsyncStream onTermination ===\n")

    let streamTask = Task {
        for await doc in documentStream(count: 10) {
            print("  Processing: \(doc)")
            if doc == "document-2" {
                print("  Breaking early...")
                break // breaking from for-await triggers onTermination(.cancelled)
            }
        }
    }
    await streamTask.value

    print("\nKey insight: cancel() sets a flag. Your code must cooperate to stop.")

    PlaygroundPage.current.finishExecution()
}
