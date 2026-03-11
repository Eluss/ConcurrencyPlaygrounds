//: # Lesson 1: `async/await` — It's Not What You Think
//:
//: **The nuance:** `await` *suspends* the current task — it does NOT block a thread.
//: This means independent `await` calls run one after another by default,
//: even though they could run concurrently. Senior devs from GCD/OperationQueue
//: often miss this and accidentally serialize work that should be parallel.
//:
//: **Real scenario:** A checkout screen that needs price, inventory, and user profile
//: before it can render. Three independent network calls — how you write the
//: `await`s determines whether users wait 900ms or 400ms.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - Simulated backend calls (each takes different time)

func fetchPrice(for productId: String) async throws -> Double {
    try await Task.sleep(for: .milliseconds(300))
    return 49.99
}

func fetchInventory(for productId: String) async throws -> Int {
    try await Task.sleep(for: .milliseconds(400))
    return 12
}

func fetchUserProfile(userId: String) async throws -> String {
    try await Task.sleep(for: .milliseconds(200))
    return "Premium Member"
}

// MARK: - ❌ The naive approach: each await runs AFTER the previous one finishes

func checkoutSequential(productId: String, userId: String) async throws {
    let start = Date()

    let price = try await fetchPrice(for: productId)       // waits 300ms
    let inventory = try await fetchInventory(for: productId) // waits another 400ms
    let profile = try await fetchUserProfile(userId: userId) // waits another 200ms
    // Total: ~900ms — the calls are serialized even though they're independent

    let elapsed = Date().timeIntervalSince(start)
    print("Sequential:  \(String(format: "%.2fs", elapsed))  price=\(price) inventory=\(inventory) profile=\(profile)")
}

// MARK: - ✅ The right approach: `async let` starts tasks immediately, await collects results

func checkoutParallel(productId: String, userId: String) async throws {
    let start = Date()

    // These three lines each START a child task immediately — no waiting yet
    async let price = fetchPrice(for: productId)
    async let inventory = fetchInventory(for: productId)
    async let profile = fetchUserProfile(userId: userId)

    // Now we wait for ALL of them — total time is the slowest one (~400ms)
    let (p, i, pr) = try await (price, inventory, profile)

    let elapsed = Date().timeIntervalSince(start)
    print("Parallel:    \(String(format: "%.2fs", elapsed))  price=\(p) inventory=\(i) profile=\(pr)")
}

// MARK: - Discussion point: when sequential IS correct

// If your calls have dependencies, sequential is right:
//
// let orderId = try await createOrder(price: price)   // must happen first
// let receipt = try await confirmOrder(id: orderId)    // needs orderId
//
// async let doesn't help here — always think "are these actually independent?"

Task {
    do {
        print("--- Checkout performance comparison ---\n")
        try await checkoutSequential(productId: "SKU-001", userId: "user-42")
        try await checkoutParallel(productId: "SKU-001", userId: "user-42")
        print("\nParallel is ~2x faster for the same results.")
    } catch {
        print("Error: \(error)")
    }
    PlaygroundPage.current.finishExecution()
}
