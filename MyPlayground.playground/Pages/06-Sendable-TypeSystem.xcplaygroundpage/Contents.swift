//: # Lesson 6: `Sendable` — The Type System Enforcing Thread Safety
//:
//: **The nuance:** `Sendable` is not just a marker protocol — it's the compiler's
//: mechanism for verifying that values crossing concurrency boundaries are safe to share.
//: Swift 6 strict concurrency makes violations *errors*, not warnings.
//: There are three distinct approaches, each with different guarantees:
//:   1. Structs (value semantics → each task gets a copy)
//:   2. Immutable final classes
//:   3. `@unchecked Sendable` (you manage safety manually)
//:
//: **Real scenario:** Enriching a list of user profiles concurrently —
//: each profile needs a network call, we want to fan out.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - ❌ NOT Sendable: mutable reference type

// In Swift 6 strict concurrency, passing this into a Task would be a compile error:
// "Capture of 'profile' with non-sendable type 'MutableProfile' in a @Sendable closure"
class MutableProfile {
    var name: String
    var score: Int
    init(name: String, score: Int) { self.name = name; self.score = score }
}

// MARK: - ✅ Option 1: Struct — value semantics, implicitly Sendable

struct UserProfile: Sendable {
    let name: String
    var score: Int
    var tier: String

    init(name: String, score: Int) {
        self.name = name
        self.score = score
        self.tier = "Standard"
    }
}

// MARK: - ✅ Option 2: Immutable final class — compiler can verify it's safe

final class ImmutableProfile: Sendable {
    let name: String
    let score: Int
    // All stored properties are `let` — provably safe across threads
    init(name: String, score: Int) { self.name = name; self.score = score }
}

// MARK: - ✅ Option 3: @unchecked Sendable — you own the safety guarantee

final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
    // Compiler trusts you. If you remove the lock, it won't warn you — bugs are yours to keep.
}

// MARK: - Concurrent enrichment using Sendable structs

func enrichProfile(_ profile: UserProfile) async -> UserProfile {
    // Each task gets its OWN COPY of the struct — mutations don't race
    try? await Task.sleep(for: .milliseconds(Int.random(in: 50...200)))
    var enriched = profile
    enriched.score += 10
    enriched.tier = enriched.score >= 110 ? "Gold" : "Standard"
    return enriched
}

func enrichAllProfiles(_ profiles: [UserProfile]) async -> [UserProfile] {
    await withTaskGroup(of: UserProfile.self) { group in
        for profile in profiles {
            group.addTask {
                await enrichProfile(profile) // safe: UserProfile is Sendable
            }
        }
        var results: [UserProfile] = []
        for await result in group { results.append(result) }
        return results
    }
}

// MARK: - Demo

Task {
    let profiles = [
        UserProfile(name: "Alice", score: 105),
        UserProfile(name: "Bob", score: 85),
        UserProfile(name: "Carol", score: 98),
        UserProfile(name: "Dan", score: 72),
    ]

    print("Before enrichment:")
    profiles.forEach { print("  \($0.name): score=\($0.score) tier=\($0.tier)") }

    let enriched = await enrichAllProfiles(profiles)

    print("\nAfter concurrent enrichment:")
    enriched.sorted { $0.score > $1.score }.forEach {
        print("  \($0.name): score=\($0.score) tier=\($0.tier)")
    }

    let counter = ThreadSafeCounter()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<100 { group.addTask { counter.increment() } }
    }
    print("\nThreadSafeCounter after 100 concurrent increments: \(counter.value) (expected 100)")

    print("\nKey insight: prefer structs → immutable classes → @unchecked Sendable, in that order.")

    PlaygroundPage.current.finishExecution()
}
