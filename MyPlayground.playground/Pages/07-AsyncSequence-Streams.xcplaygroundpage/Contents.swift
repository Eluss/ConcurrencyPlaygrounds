//: # Lesson 7: `AsyncSequence` — Streams of Values Over Time
//:
//: **The nuance:** `AsyncStream` is the concurrency-native replacement for
//: Combine publishers and delegate callbacks. The tricky parts:
//: - `AsyncStream` has a *buffer* — values can pile up if the consumer is slow (backpressure)
//: - `continuation.onTermination` is your cleanup hook — always set it
//: - Breaking out of `for await` cancels the stream (triggers `onTermination`)
//: - Bridging delegate/callback APIs requires careful lifetime management
//:
//: **Real scenario:** A live search bar. User keystrokes arrive as callbacks,
//: we want to debounce them, then pass a clean stream of "settled" queries
//: to the search logic.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - Legacy delegate-based API (what we're bridging FROM)

protocol SearchDelegate: AnyObject {
    func didReceiveResults(_ results: [String], for query: String)
}

class LegacySearchEngine: SearchDelegate {
    weak var delegate: SearchDelegate?

    func search(query: String) {
        // Simulates async callback from a framework (URLSession, CoreData, etc.)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.delegate?.didReceiveResults(["\(query): result A", "\(query): result B"], for: query)
        }
    }

    func didReceiveResults(_ results: [String], for query: String) {}
}

// MARK: - Bridge: delegate → AsyncStream

// This pattern wraps any callback/delegate API into an AsyncStream.
// The key: continuation lives as long as the stream is consumed.
func makeSearchResultsStream(engine: LegacySearchEngine, query: String) -> AsyncStream<[String]> {
    AsyncStream { continuation in
        // Adapter object that implements the delegate and forwards to the continuation
        class Adapter: SearchDelegate {
            let continuation: AsyncStream<[String]>.Continuation
            init(_ continuation: AsyncStream<[String]>.Continuation) {
                self.continuation = continuation
            }
            func didReceiveResults(_ results: [String], for query: String) {
                continuation.yield(results)
                continuation.finish() // single-shot in this example
            }
        }

        let adapter = Adapter(continuation)
        engine.delegate = adapter

        // ✅ Cleanup when stream is cancelled or consumer breaks out
        continuation.onTermination = { _ in
            print("  [stream] cleaned up for query: \(query)")
            engine.delegate = nil
        }

        engine.search(query: query)
    }
}

// MARK: - Debounce operator built on AsyncStream

func debounced(
    _ upstream: AsyncStream<String>,
    for duration: Duration
) -> AsyncStream<String> {
    AsyncStream { continuation in
        Task {
            var pendingTask: Task<Void, Never>?

            for await value in upstream {
                pendingTask?.cancel()
                pendingTask = Task {
                    try? await Task.sleep(for: duration)
                    guard !Task.isCancelled else { return }
                    continuation.yield(value)
                }
            }
            // Upstream finished — wait for any pending debounce then close
            try? await Task.sleep(for: duration)
            continuation.finish()
        }
    }
}

// MARK: - Simulated keystroke stream

func simulateTyping(_ text: String, keystrokeDelay: Duration) -> AsyncStream<String> {
    AsyncStream { continuation in
        Task {
            var accumulated = ""
            for char in text {
                try? await Task.sleep(for: keystrokeDelay)
                accumulated.append(char)
                continuation.yield(accumulated)
            }
            continuation.finish()
        }
    }
}

// MARK: - Demo

Task {
    print("=== Live search with debounce ===\n")
    print("User typing: 'swift actor'")
    print("Debounce: 200ms — only settled queries reach the search engine\n")

    let keystrokes = simulateTyping("swift actor", keystrokeDelay: .milliseconds(80))
    let settled = debounced(keystrokes, for: .milliseconds(200))

    let engine = LegacySearchEngine()
    var searchCount = 0

    for await query in settled {
        searchCount += 1
        print("Searching for: '\(query)'")

        for await results in makeSearchResultsStream(engine: engine, query: query) {
            results.forEach { print("  \($0)") }
        }
    }

    print("\nTotal searches fired: \(searchCount) (without debounce it would be 11)")
    print("Key insight: debounce is just an operator — AsyncStream composes naturally.")

    PlaygroundPage.current.finishExecution()
}
