//: # Lesson 8: Continuations — Bridging the Old World
//:
//: **The nuance:** `withCheckedContinuation` is the escape hatch for callback APIs,
//: but the rules are strict:
//: - You MUST call `resume` exactly once. Zero times = task hangs forever. Twice = crash.
//: - `Checked` variants trap on misuse (debug builds). `Unsafe` skips the check for performance.
//: - The continuation captures `self` — watch for retain cycles and lifetime issues.
//: - You cannot `throw` from inside the closure body — errors go through `resume(throwing:)`.
//:
//: **Real scenario:** Wrapping a legacy completion-handler network client
//: so it can be called with `try await`.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - Legacy callback-based API (think: Alamofire 4, old URLSession wrappers)

class LegacyNetworkClient {
    enum NetworkError: Error { case serverError(Int), noData, timeout }

    func get(_ url: String, completion: @escaping (Result<Data, Error>) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            if url.contains("/error") {
                completion(.failure(NetworkError.serverError(500)))
            } else if url.contains("/empty") {
                completion(.success(Data()))
            } else {
                completion(.success(Data(#"{"status":"ok"}"#.utf8)))
            }
        }
    }
}

// MARK: - ✅ Correct wrapping with withCheckedThrowingContinuation

extension LegacyNetworkClient {
    func get(_ url: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            get(url) { result in
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let error): continuation.resume(throwing: error)
                }
                // Exactly ONE resume call on ALL code paths. Checked variant will
                // crash with a clear message if you violate this.
            }
        }
    }
}

// MARK: - ❌ Common mistake 1: early return without resuming

// func brokenWrap(_ url: String) async throws -> Data {
//     try await withCheckedThrowingContinuation { continuation in
//         guard url.hasPrefix("https") else {
//             return  // ← forgot to resume! Task hangs forever
//         }
//         networkCall(url) { continuation.resume(returning: $0) }
//     }
// }
//
// Fix: continuation.resume(throwing: MyError.invalidURL); return

// MARK: - ❌ Common mistake 2: resuming twice (crashes with Checked, silent corruption with Unsafe)

// func doubleResume(_ url: String) async throws -> Data {
//     try await withCheckedThrowingContinuation { continuation in
//         networkCall(url) { data in
//             continuation.resume(returning: data)
//         }
//         continuation.resume(throwing: MyError.timeout) // ← second resume = crash
//     }
// }

// MARK: - Wrapping a multi-callback API (only fires ONE result)

// Some APIs call completion AND an error handler separately
func legacyFetchWithSeparateCallbacks(
    onSuccess: @escaping (Data) -> Void,
    onError: @escaping (Error) -> Void
) {
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
        if Bool.random() {
            onSuccess(Data("ok".utf8))
        } else {
            onError(URLError(.timedOut))
        }
    }
}

func fetchWithSeparateCallbacks() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        // Use a flag to guard against the (buggy) case where both fire
        var resumed = false

        legacyFetchWithSeparateCallbacks {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: $0)
        } onError: {
            guard !resumed else { return }
            resumed = true
            continuation.resume(throwing: $0)
        }
    }
}

// MARK: - Demo

Task {
    let client = LegacyNetworkClient()

    print("=== Successful request ===")
    do {
        let data = try await client.get("https://api.example.com/data")
        print("Response: \(String(data: data, encoding: .utf8) ?? "-")")
    } catch {
        print("Error: \(error)")
    }

    print("\n=== Failed request ===")
    do {
        let data = try await client.get("https://api.example.com/error")
        print("Response: \(String(data: data, encoding: .utf8) ?? "-")")
    } catch {
        print("Expected error: \(error)")
    }

    print("\n=== Separate callbacks ===")
    for _ in 1...3 {
        do {
            let data = try await fetchWithSeparateCallbacks()
            print("  ✓ Got: \(String(data: data, encoding: .utf8) ?? "-")")
        } catch {
            print("  ✗ Error: \(error.localizedDescription)")
        }
    }

    print("\nKey rule: one continuation, one resume, on every code path.")

    PlaygroundPage.current.finishExecution()
}
