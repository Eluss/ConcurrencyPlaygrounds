//: # Lesson 4: Actors — Reentrancy Is the Real Trap
//:
//: **The nuance:** Actors serialize access to their state — but only while NOT suspended.
//: When an actor hits an `await`, it can process OTHER incoming messages before resuming.
//: This is called *reentrancy*, and it breaks the check-then-act pattern (TOCTOU).
//:
//: **Real scenario:** An actor-based cache. The naive implementation checks if a key
//: exists, then fetches if not. But between the check and the store, another
//: caller sneaks in — and you end up with duplicate network requests.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// #Interesting

var fetchCount = 0 // global counter to observe duplicate fetches

@MainActor
func fetchFromNetwork(key: String) async -> String {
    fetchCount += 1
    let currentFetch = fetchCount
    print("  → network fetch #\(currentFetch) for '\(key)' started")
    try? await Task.sleep(for: .milliseconds(300))
    print("  ← network fetch #\(currentFetch) for '\(key)' completed")
    return "value:\(key)"
}

// MARK: - ❌ Buggy: TOCTOU via reentrancy

actor BuggyCache {
    private var cache: [String: String] = [:]

    func value(for key: String) async -> String {
        if let hit = cache[key] {
            return hit // fast path — actor is NOT suspended here, safe
        }

        // ⚠️ Actor suspends at this await. Another `value(for:)` call can now enter.
        // That second call also sees cache[key] == nil and also starts a fetch.
        let result = await fetchFromNetwork(key: key)

        // Both callers eventually store the same result — wasteful, and in
        // non-idempotent cases (e.g. deducting inventory) this is a real bug.
        cache[key] = result
        return result
    }
}

// MARK: - ✅ Fixed: coalesce in-flight requests using a Task as a future

actor CorrectCache {
    private var cache: [String: String] = [:]
    private var inFlight: [String: Task<String, Never>] = [:]

    func value(for key: String) async -> String {
        if let hit = cache[key] { return hit }

        // If a fetch is already in progress for this key, join it instead of starting another
        if let existing = inFlight[key] {
            print("  ↩ joining in-flight request for '\(key)'")
            return await existing.value
        }

        let task = Task { await fetchFromNetwork(key: key) }
        inFlight[key] = task

        let result = await task.value  // actor suspends here, but new callers find inFlight[key]

        cache[key] = result
        inFlight.removeValue(forKey: key)
        return result
    }
}

// MARK: - Demo

Task {
    print("=== BuggyCache: concurrent requests for same key ===\n")
    fetchCount = 0
    let buggy = BuggyCache()

    // Both requests see cache miss simultaneously
    async let a = buggy.value(for: "user-profile")
    async let b = buggy.value(for: "user-profile")
    let _ = await (a, b)
    print("\nFetch count: \(fetchCount) (expected 1, got \(fetchCount) — duplicate!)\n")

    print("=== CorrectCache: in-flight deduplication ===\n")
    fetchCount = 0
    let correct = CorrectCache()

    async let c = correct.value(for: "user-profile")
    async let d = correct.value(for: "user-profile")
    let _ = await (c, d)
    print("\nFetch count: \(fetchCount) (expected 1, got \(fetchCount) ✓)\n")

    print("Key insight: actor isolation holds while RUNNING, not while SUSPENDED.")
    print("Any state you read before an `await` may be stale after it resumes.")

    PlaygroundPage.current.finishExecution()
}
