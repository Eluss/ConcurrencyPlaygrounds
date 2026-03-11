//: # Lesson 12: `Task {}` vs `Task.detached {}` — What Gets Inherited
//:
//: Both create *unstructured* tasks (no parent-child lifetime guarantee),
//: but they differ in what they inherit from the creating context:
//:
//: | Property          | `Task {}`         | `Task.detached {}`  |
//: |-------------------|-------------------|---------------------|
//: | Actor isolation   | Inherited ✓       | None ✗              |
//: | Priority          | Inherited ✓       | `.medium` (default) |
//: | Task locals       | Inherited ✓       | Baseline value ✗    |
//:
//: **Why actor inheritance matters:** Calling `Task { }` from a `@MainActor`
//: context runs the task body on the MainActor. That means `await`-free work
//: inside it blocks the main thread — the same problem you'd have calling
//: a synchronous method.
//:
//: **Real scenario:** A ViewModel fires background work. `Task { }` keeps it
//: on the MainActor (fine for quick UI updates, wrong for CPU work).
//: `Task.detached { }` escapes to a background thread but loses all context —
//: including request IDs used for distributed tracing.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - TaskLocal for distributed tracing / request correlation

enum TraceID {
    @TaskLocal static var current: String = "none"
}

// MARK: - Simulated CPU-heavy work (just a delay here)

func crunchNumbers() async -> Int {
    // In real code this would be CPU-bound — wrong to do on MainActor
    try? await Task.sleep(for: .milliseconds(100))
    return 42
}

// MARK: - A @MainActor type (e.g., a ViewModel or UIViewController)

nonisolated(unsafe) func isMainThread() -> Bool {
    Thread.isMainThread
}

@MainActor
class SearchViewModel {

    // Called from the MainActor (e.g., user tapped Search)
    func search(query: String) {
        print("search() — isMainThread: \(Thread.isMainThread), TraceID: \(TraceID.current)\n")

        // ── Task { } ────────────────────────────────────────────────────────
        // Inherits @MainActor isolation → body runs on main thread.
        // ✓ Can directly read/write MainActor-isolated properties.
        // ✗ CPU work here would jank the UI.
        // ✓ TraceID is inherited — great for logging/tracing.
        Task {
            print("  Task {}:")
            print("    isMainThread  = \(isMainThread())   ← inherited MainActor isolation")
            print("    priority      = \(Task.currentPriority)  ← inherited from caller")
            print("    TraceID       = \(TraceID.current)       ← inherited task local\n")

            // Fine — we're on the MainActor, no data race
            let _ = query.uppercased()
        }

        // ── Task.detached { } ───────────────────────────────────────────────
        // No actor context → runs on a background thread from the cooperative pool.
        // ✓ Right place for CPU-heavy / blocking work.
        // ✗ Cannot access MainActor-isolated state without `await MainActor.run { }`
        // ✗ TraceID resets to its baseline — context is lost.
        Task.detached(priority: .utility) {
            print("  Task.detached {}:")
            print("    isMainThread  = \(isMainThread())   ← no actor context, runs off main")
            print("    priority      = \(Task.currentPriority)  ← explicitly set, not inherited")
            print("    TraceID       = \(TraceID.current)       ← reset to baseline 'none'\n")

            // Must hop back to MainActor to touch isolated state:
            let result = await crunchNumbers()
            await MainActor.run {
                print("  Back on MainActor after detached work — result: \(result)")
            }
        }
    }
}

// MARK: - Demo

Task(priority: .userInitiated) {
    // Set a task local for this call tree — simulating a traced request
    await TraceID.$current.withValue("req-7f3a-9b12") {
        print("=== Running with TraceID: \(TraceID.current) ===\n")

        let vm = await SearchViewModel()
        await vm.search(query: "concurrency")

        // Give both tasks time to run
        try? await Task.sleep(for: .milliseconds(400))

        print("""
        Key insights:
        • Task {}: inherits actor isolation, priority, and task locals.
          Use when you need to stay on the same actor or propagate context.
        • Task.detached {}: inherits nothing. Use for CPU-intensive work
          that must not run on a specific actor (especially MainActor).
        • Task locals (e.g. TraceID) flow into Task {} but NOT Task.detached {}.
          If you need context propagation, prefer Task {} or structured concurrency.
        • Pattern for heavy work from @MainActor:
            Task.detached { let r = await compute(); await MainActor.run { update(r) } }
        """)

        PlaygroundPage.current.finishExecution()
    }
}
