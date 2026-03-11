//: # Lesson 11: `@TaskLocal` — Context That Flows Through the Task Tree
//:
//: **The problem:** You have a value (e.g. a request ID) that needs to be
//: readable deep inside an async call stack — 10 function calls down —
//: without being passed as a parameter to every function along the way.
//:
//: Options and their problems:
//: - **Parameter threading:** every function signature needs the extra param. Pollutes APIs.
//: - **Global var:** thousands of concurrent tasks clobber each other. Data races.
//: - **`@TaskLocal`:** scoped to the current task tree. No parameters, no races. ✓
//:
//: **How it works:**
//: - Declared as a static property with `@TaskLocal`. Has a default value.
//: - Set for a scope with `TaskLocal.$name.withValue(x) { ... }`.
//: - Automatically restores the previous value when the scope exits.
//: - Child tasks (async let, TaskGroup, Task {}) inherit a *copy* at creation time.
//: - `Task.detached {}` does NOT inherit — it gets the default value.
//:
//: **Real scenario:** A server handles thousands of concurrent requests.
//: Every log line should include the request ID without threading it through
//: every function. `@TaskLocal` makes this zero-friction.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - Declare TaskLocals

// Convention: nest them in an enum to namespace them cleanly.
// The default value is what any task sees if withValue was never called.
enum RequestContext {
    @TaskLocal static var requestID: String = "none"
    @TaskLocal static var userID: String    = "anonymous"
}

// MARK: - Helper — log with automatic context, no parameters needed

func log(_ message: String) {
    print("  [req:\(RequestContext.requestID) user:\(RequestContext.userID)] \(message)")
}

// MARK: - A realistic async call stack — nobody passes the IDs manually

func validateInput(_ query: String) async {
    log("validateInput('\(query)')")
    try? await Task.sleep(for: .milliseconds(50))
}

func fetchFromDatabase(query: String) async -> [String] {
    log("fetchFromDatabase — hitting DB...")
    try? await Task.sleep(for: .milliseconds(150))
    log("fetchFromDatabase — done")
    return ["result-A", "result-B"]
}

func rankResults(_ results: [String]) async -> [String] {
    log("rankResults — applying ML ranking")
    try? await Task.sleep(for: .milliseconds(80))
    return results.reversed()
}

func handleSearch(query: String) async -> [String] {
    log("handleSearch started")
    await validateInput(query)
    let raw = await fetchFromDatabase(query: query)
    let ranked = await rankResults(raw)
    log("handleSearch completed")
    return ranked
}

// MARK: - Demo 1: Basic usage — set context, call deep stack, context auto-restores

Task {
    print("=== Demo 1: Context flows through call stack automatically ===\n")

    // No RequestContext set — all logs print "none / anonymous"
    log("Before withValue — sees default")

    await RequestContext.$requestID.withValue("req-f3a9") {
        await RequestContext.$userID.withValue("user-42") {
            // Everything called inside here — however deep — sees these values
            _ = await handleSearch(query: "swift concurrency")
        }
        // userID is restored to "anonymous" here
        log("After inner withValue — userID is restored")
    }

    // Both restored
    log("After outer withValue — both restored\n")
}

// MARK: - Demo 2: Concurrent requests — each gets its own isolated context

Task {
    try? await Task.sleep(for: .milliseconds(700))  // let Demo 1 finish
    print("\n=== Demo 2: Concurrent requests — contexts don't bleed into each other ===\n")

    // Simulate 3 concurrent requests hitting the server at the same time.
    // Each request sets its OWN context — they run concurrently but never see each other's IDs.
    await withTaskGroup(of: Void.self) { group in
        let requests = [
            ("req-111", "user-A", "actors"),
            ("req-222", "user-B", "sendable"),
            ("req-333", "user-C", "async let"),
        ]

        for (reqID, userID, query) in requests {
            group.addTask {
                await RequestContext.$requestID.withValue(reqID) {
                    await RequestContext.$userID.withValue(userID) {
                        _ = await handleSearch(query: query)
                    }
                }
            }
        }
    }

    print()
}

// MARK: - Demo 3: Inheritance rules — Task {} vs Task.detached {}

Task {
    try? await Task.sleep(for: .milliseconds(1500))  // let Demo 2 finish
    print("\n=== Demo 3: Inheritance — Task {} copies, Task.detached {} resets ===\n")

    await RequestContext.$requestID.withValue("req-parent") {

        // Task {}: inherits a COPY of the current TaskLocal values at spawn time
        let t1 = Task {
            log("Task {} — inherits parent's context ✓")
        }

        // Task.detached {}: inherits NOTHING — sees the default value
        let t2 = Task.detached {
            log("Task.detached {} — sees default, not parent's context ✗")
        }

        _ = await (t1.value, t2.value)

        

        print()
    }

    print("""
    Key insights:
    • @TaskLocal stores a value scoped to a task tree. Default applies when unset.
    • withValue sets the value for the duration of a closure, then auto-restores.
    • All async functions called within withValue see the value — no param passing.
    • Concurrent tasks (via TaskGroup) each get their own copy — no bleeding.
    • Task {} inherits a snapshot at spawn time. Task.detached {} sees the default.
    • You cannot assign directly (no `RequestContext.requestID = x`).
      This design prevents the mutation races that thread-locals are prone to.
    • Common uses: request IDs, trace/span context, logging metadata, feature flags.
    """)

    PlaygroundPage.current.finishExecution()
}
