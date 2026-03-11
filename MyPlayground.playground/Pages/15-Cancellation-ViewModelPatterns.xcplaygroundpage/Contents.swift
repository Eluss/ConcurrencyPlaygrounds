//: # Lesson 15: Cancellation in ViewModels — Task Lifetime Is Your Responsibility
//:
//: `Task {}` creates an *unstructured* task — it has no parent, so nothing cancels
//: it automatically. In a ViewModel this means:
//:
//: - Tasks spawned inside `init` or action handlers outlive the ViewModel unless
//:   you cancel them explicitly in `deinit`.
//: - Triggering the same action twice (e.g. typing a new search query) spawns a
//:   second task that races with the first — both write to state, last one wins.
//:
//: SwiftUI's `.task(id:)` modifier solves the second problem automatically:
//: it cancels the running task and re-runs it whenever `id` changes.
//: In a plain ViewModel you must implement the same pattern by hand.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - Simulated search

func fetchResults(for query: String) async throws -> [String] {
    print("    [fetch] '\(query)' started")
    try await Task.sleep(for: .milliseconds(300))
    print("    [fetch] '\(query)' completed ✓")
    return ["\(query)-result-1", "\(query)-result-2"]
}

// MARK: - ❌ Example 2a: naive ViewModel — no task cancellation on new query

@MainActor
class SearchViewModelNaive {
    var results: [String] = []

    func search(query: String) {
        // Every call spawns a fresh Task — previous one keeps running.
        // Both tasks will eventually write to `results`. Race condition.
        Task {
            do {
                results = try await fetchResults(for: query)
                print("    [naive] results set to: \(results)")
            } catch is CancellationError {
                print("    [naive] '\(query)' cancelled")
            }
        }
    }
}

// MARK: - ✅ Example 2b: correct ViewModel — cancel previous task before starting new one
//
// This is exactly what SwiftUI's `.task(id:)` does internally:
// when `id` changes, it cancels the in-flight task and starts a new one.

@MainActor
class SearchViewModelCorrect {
    var results: [String] = []
    private var searchTask: Task<Void, Never>?

    func search(query: String) {
        searchTask?.cancel() // cancel whatever was running
        searchTask = Task {
            do {
                results = try await fetchResults(for: query)
                print("    [correct] results set to: \(results)")
            } catch is CancellationError {
                print("    [correct] '\(query)' cancelled ✓")
            } catch {
                print("    [correct] '\(query)' failed: \(error)")
            }
        }
    }
}

// MARK: - ❌ Example 3a: ViewModel that forgets to cancel on deinit

class LeakyViewModel {
    init() {
        print("    [leaky] init")
        // Spawns a long-running task — nobody will ever cancel it
        Task {
            do {
                print("    [leaky] task started, will run for 1s...")
                try await Task.sleep(for: .seconds(1))
                print("    [leaky] task completed — ViewModel was already deallocated ⚠️")
            } catch is CancellationError {
                print("    [leaky] task cancelled")
            }
        }
    }

    deinit {
        print("    [leaky] deinit — but task is still running!")
    }
}

// MARK: - ✅ Example 3b: ViewModel that cancels its task on deinit

class ProperViewModel {
    private var task: Task<Void, Never>?

    init() {
        print("    [proper] init")
        task = Task {
            do {
                print("    [proper] task started, will run for 1s...")
                try await Task.sleep(for: .seconds(1))
                print("    [proper] task completed")
            } catch is CancellationError {
                print("    [proper] task cancelled ✓ — cleaned up on deinit")
            } catch {
                print("    [proper] failed: \(error)")
            }
        }
    }

    deinit {
        task?.cancel()
        print("    [proper] deinit — task cancelled")
    }
}

// MARK: - Demo

Task {
    // ── Example 2: .task(id:) pattern ────────────────────────────────────────
    print("=== Example 2a: naive search — rapid queries cause races ===\n")

    let naive = await SearchViewModelNaive()
    await naive.search(query: "swift")
    try await Task.sleep(for: .milliseconds(100)) // 100ms later, user types more
    await naive.search(query: "swift concurrency")
    // Both fetches run — 'swift' completes after 'swift concurrency' and overwrites results
    try await Task.sleep(for: .milliseconds(500))

    print()
    print("=== Example 2b: correct search — previous task cancelled on new query ===\n")

    let correct = await SearchViewModelCorrect()
    await correct.search(query: "swift")
    try await Task.sleep(for: .milliseconds(100))
    await correct.search(query: "swift concurrency")
    // 'swift' fetch is cancelled — only 'swift concurrency' completes and sets results
    try await Task.sleep(for: .milliseconds(500))

    // ── Example 3: deinit cancellation ───────────────────────────────────────
    print()
    print("=== Example 3a: leaky ViewModel — task outlives the object ===\n")

    var leaky: LeakyViewModel? = LeakyViewModel()
    try await Task.sleep(for: .milliseconds(200))
    leaky = nil // deallocated — but the task keeps running for another 800ms
    try await Task.sleep(for: .milliseconds(1000))

    print()
    print("=== Example 3b: proper ViewModel — task cancelled on deinit ===\n")

    var proper: ProperViewModel? = ProperViewModel()
    try await Task.sleep(for: .milliseconds(200))
    proper = nil // deinit calls task?.cancel() — task stops immediately
    try await Task.sleep(for: .milliseconds(1000))

    print("""

    Key insights:
    • Task {} has no parent — nothing cancels it automatically when its owner goes away.
    • Rapid re-triggers spawn racing tasks. Fix: cancel the previous handle before
      starting a new one. This is exactly what SwiftUI's .task(id:) does for you.
    • Always store Task handles in ViewModels and call cancel() in deinit to prevent
      tasks from outliving the object that created them.
    """)

    PlaygroundPage.current.finishExecution()
}
