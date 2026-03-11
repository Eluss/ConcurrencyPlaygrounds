//: # Lesson 3: `TaskGroup` — Concurrency With Dynamic Shape
//:
//: **The nuance:** `async let` requires knowing the number of tasks at compile time.
//: `withTaskGroup` handles dynamic fan-out (N items from a runtime collection).
//: The tricky parts:
//: - Results arrive via `for await` in *completion order*, not submission order
//: - `withThrowingTaskGroup` cancels the whole group on the first throw
//: - `withTaskGroup` (non-throwing) forces you to handle errors per-task
//:
//: **Real scenario:** Batch image upload. Fan out N uploads concurrently,
//: collect results as each finishes, handle partial failures gracefully.

// #Interesting

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

struct UploadResult {
    let imageId: String
    let success: Bool
    let error: String?
}

// MARK: - Simulated upload (variable speed, ~20% failure rate)

func uploadImage(id: String) async throws -> UploadResult {
    let durationMs = [100, 200, 300, 400, 500].randomElement()!
    try await Task.sleep(for: .milliseconds(durationMs))

    if id.hasSuffix("3") || id.hasSuffix("6") { // deterministic "failures" for demo
        throw URLError(.networkConnectionLost)
    }
    return UploadResult(imageId: id, success: true, error: nil)
}

// MARK: - ❌ withThrowingTaskGroup: first failure cancels everything

func batchUploadFailFast(imageIds: [String]) async throws -> [UploadResult] {
    try await withThrowingTaskGroup(of: UploadResult.self) { group in
        for id in imageIds {
            group.addTask { try await uploadImage(id: id) }
        }

        var results: [UploadResult] = []
        for try await result in group {  // ⚠️ first throw here exits the loop and cancels remaining tasks
            results.append(result)
            print("  ✓ \(result.imageId)")
        }
        return results
    }
}

// MARK: - ✅ withTaskGroup: each task handles its own error, group always completes

func batchUploadResilient(imageIds: [String]) async -> (succeeded: [String], failed: [String]) {
    var succeeded: [String] = []
    var failed: [String] = []

    await withTaskGroup(of: UploadResult.self) { group in
        for id in imageIds {
            group.addTask {
                do {
                    return try await uploadImage(id: id)
                } catch {
                    return UploadResult(imageId: id, success: false, error: error.localizedDescription)
                }
            }
        }

        // Results arrive in COMPLETION ORDER — faster uploads report first
        for await result in group {
            if result.success {
                succeeded.append(result.imageId)
                print("  ✓ \(result.imageId)")
            } else {
                failed.append(result.imageId)
                print("  ✗ \(result.imageId): \(result.error ?? "unknown")")
            }
        }
    }

    return (succeeded, failed)
}

// MARK: - Demo

Task {
    let imageIds = (1...8).map { "IMG-\(String(format: "%03d", $0))" }

    print("=== Fail-fast (withThrowingTaskGroup) ===\n")
    do {
        let results = try await batchUploadFailFast(imageIds: imageIds)
        print("Uploaded \(results.count) images")
    } catch {
        print("  ✗ Upload batch failed: \(error.localizedDescription)")
        print("  Remaining uploads were cancelled\n")
    }

    print("\n=== Resilient (withTaskGroup, per-task error handling) ===\n")
    let start = Date()
    let (succeeded, failed) = await batchUploadResilient(imageIds: imageIds)
    let elapsed = Date().timeIntervalSince(start)

    print("\nDone in \(String(format: "%.2fs", elapsed))")
    print("Succeeded: \(succeeded.count)/\(imageIds.count), Failed: \(failed.count)/\(imageIds.count)")
    print("\nNote: all 8 ran concurrently — elapsed time ≈ slowest individual upload")

    PlaygroundPage.current.finishExecution()
}
