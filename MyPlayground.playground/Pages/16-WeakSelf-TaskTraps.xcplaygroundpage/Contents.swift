//: # Lesson 16: `weak self` and Tasks — Traps and Correct Patterns
//:
//: Developers coming from GCD and completion handlers reach for `[weak self]`
//: instinctively. In Swift concurrency this reflex causes more bugs than it prevents.
//:
//: ## ViewModel traps
//:
//: | Pattern                              | Problem                                      |
//: |--------------------------------------|----------------------------------------------|
//: | `Task { [weak self] in ... }`        | Unnecessary; risks silent nil updates        |
//: | `guard let self else { return }`     | Silently drops completed work                |
//: | `@MainActor` class + `[weak self]`   | Doubly unnecessary; actor serialises access  |
//: | Storing Task + strong self           | Not a cycle; fix with `deinit` cancel        |
//:
//: ## Closure traps
//:
//: | Pattern                                         | Problem                              |
//: |-------------------------------------------------|--------------------------------------|
//: | Retained closure without `[weak self]`          | Retain cycle — ViewModel never freed |
//: | `{ [weak self] in Task { [weak self] in } }`    | Double-weak; extra nil window        |
//: | `{ [weak self] in Task { /* strong */ } }`      | ✅ Correct pattern                   |

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

func fetchData(label: String) async throws -> String {
    try await Task.sleep(for: .milliseconds(200))
    return "\(label)-result"
}

// MARK: - Trap 1: unnecessary [weak self] — risks silent dropped update

@MainActor
class ViewModelWeakSelfNaive {
    var result: String = ""
    let label: String

    init(label: String) { self.label = label }

    func load() {
        Task { [weak self] in                   // ← unnecessary, risky
            guard let self else { return }      // ← if nil, update silently dropped
            let data = try await fetchData(label: label)
            self.result = data
            print("  [weak-naive] '\(label)' result set: \(result)")
        }
    }
}

// MARK: - Trap 2: guard-let bails out after completed work

@MainActor
class ViewModelGuardLetBail {
    var result: String = ""
    let label: String

    init(label: String) { self.label = label }

    func load() {
        Task { [weak self] in
            // fetchData completes successfully — real work done, network used
            let data = try? await fetchData(label: self?.label ?? "?")
            // But if self was released while awaiting, the update is silently lost
            guard let self else {
                print("  [guard-bail] — fetch completed but self was nil, update lost ⚠️")
                return
            }
            self.result = data ?? ""
            print("  [guard-bail] '\(label)' result set: \(result)")
        }
    }
}

// MARK: - Trap 3: @MainActor class — [weak self] is doubly unnecessary

@MainActor
class ViewModelMainActor {
    var result: String = ""
    let label: String

    init(label: String) { self.label = label }

    func load() {
        // @MainActor already serialises all access to this class.
        // Task {} inherits @MainActor isolation — no data race is possible.
        // [weak self] adds nil-risk for zero benefit.
        Task { [weak self] in                   // ← doubly unnecessary on @MainActor
            guard let self else { return }
            let data = try? await fetchData(label: label)
            self.result = data ?? ""
            print("  [main-actor-weak] '\(label)' result set: \(result)")
        }
    }
}

// MARK: - ✅ Correct ViewModel pattern: strong self + cancel in deinit

@MainActor
class ViewModelCorrect {
    var result: String = ""
    let label: String
    private var loadTask: Task<Void, Never>?

    init(label: String) { self.label = label }

    func load() {
        loadTask?.cancel()
        loadTask = Task {
            do {
                let data = try await fetchData(label: label)
                result = data                   // strong self, @MainActor, safe
                print("  [correct] '\(label)' result set: \(result)")
            } catch is CancellationError {
                print("  [correct] '\(label)' cancelled ✓")
            } catch {
                print("  [correct] '\(label)' error: \(error)")
            }
        }
    }

    deinit {
        loadTask?.cancel()                      // stops work AND releases self promptly
    }
}

// MARK: - Trap 4: retained closure without [weak self] — retain cycle

class ViewModelRetainCycle {
    let label: String
    nonisolated(unsafe) var onTimer: (() -> Void)?  // stored closure — owns self strongly

    init(label: String) {
        self.label = label
        // Closure stored on self, captures self strongly → cycle
        // self → onTimer → closure → self  (never freed)
        onTimer = {
            Task {
                let _ = try? await fetchData(label: self.label) // strong self in cycle
                print("  [retain-cycle] '\(self.label)' — ViewModel never freed ⚠️")
            }
        }
        print("  [retain-cycle] '\(label)' init")
    }

    deinit { print("  [retain-cycle] '\(label)' deinit") } // never called
}

// MARK: - Trap 5: double [weak self] — unnecessary nil window inside Task

class ViewModelDoubleWeak {
    let label: String
    nonisolated(unsafe) var onTimer: (() -> Void)?

    init(label: String) {
        self.label = label
        onTimer = { [weak self] in              // ✓ weak here — breaks cycle
            Task { [weak self] in               // ✗ weak again — self can go nil
                guard let self else {           //   between outer firing and Task body
                    print("  [double-weak] '\(label)' — self nil inside Task ⚠️")
                    return
                }
                let _ = try? await fetchData(label: self.label)
                print("  [double-weak] '\(self.label)' completed")
            }
        }
        print("  [double-weak] '\(label)' init")
    }

    deinit { print("  [double-weak] '\(label)' deinit") }
}

// MARK: - ✅ Correct closure pattern: weak in closure, guard once, strong into Task

class ViewModelClosureCorrect {
    let label: String
    nonisolated(unsafe) var onTimer: (() -> Void)?

    init(label: String) {
        self.label = label
        onTimer = { [weak self] in              // ✓ weak here — breaks the cycle
            guard let self else { return }      // ✓ guard once, before spawning Task
            Task {                              // ✓ no [weak self] — self is strong here,
                let _ = try? await fetchData(label: self.label) //  guaranteed non-nil
                print("  [closure-correct] '\(self.label)' completed ✓")
            }
        }
        print("  [closure-correct] '\(label)' init")
    }

    deinit { print("  [closure-correct] '\(label)' deinit") }
}

// MARK: - Demo

Task {
    // ── Trap 1 & 2: weak self drops updates ──────────────────────────────────
    print("=== Trap 1: unnecessary [weak self] — update silently dropped ===\n")

    var vm1: ViewModelWeakSelfNaive? = ViewModelWeakSelfNaive(label: "trap1")
    vm1?.load()
    // Release before fetch completes — self becomes nil, update dropped
    vm1 = nil
    try await Task.sleep(for: .milliseconds(400))

    print()
    print("=== Trap 2: guard-let bail — completed fetch result thrown away ===\n")

    var vm2: ViewModelGuardLetBail? = ViewModelGuardLetBail(label: "trap2")
    vm2?.load()
    vm2 = nil                                   // released mid-fetch
    try await Task.sleep(for: .milliseconds(400))

    print()
    print("=== ✅ Correct ViewModel: strong self + deinit cancel ===\n")

    var vm3: ViewModelCorrect? = ViewModelCorrect(label: "correct")
    vm3?.load()
    try await Task.sleep(for: .milliseconds(400)) // let it finish
    vm3 = nil

    print()
    print("=== ✅ Correct ViewModel: cancelled via deinit before completion ===\n")

    var vm4: ViewModelCorrect? = ViewModelCorrect(label: "correct-cancelled")
    vm4?.load()
    try await Task.sleep(for: .milliseconds(50))
    vm4 = nil                                   // deinit cancels in-flight task
    try await Task.sleep(for: .milliseconds(400))

    // ── Closure traps ─────────────────────────────────────────────────────────
    print()
    print("=== Trap 4: retained closure — retain cycle, deinit never called ===\n")

    var vm5: ViewModelRetainCycle? = ViewModelRetainCycle(label: "cycle")
    vm5?.onTimer?()
    vm5 = nil                                   // reference dropped, but cycle keeps it alive
    try await Task.sleep(for: .milliseconds(400))
    // deinit above is never printed

    print()
    print("=== Trap 5: double [weak self] — self can be nil inside Task ===\n")

    var vm6: ViewModelDoubleWeak? = ViewModelDoubleWeak(label: "double-weak")
    vm6?.onTimer?()
    vm6 = nil                                   // released between closure fire and Task body
    try await Task.sleep(for: .milliseconds(400))

    print()
    print("=== ✅ Correct closure: [weak self] once, guard, strong into Task ===\n")

    var vm7: ViewModelClosureCorrect? = ViewModelClosureCorrect(label: "closure-correct")
    vm7?.onTimer?()
    try await Task.sleep(for: .milliseconds(400))
    vm7 = nil
    try await Task.sleep(for: .milliseconds(100))

    print("""

    Key insights:
    • Task {} does NOT create a retain cycle — [weak self] inside is almost never needed.
    • [weak self] in a Task risks silent nil: self dies mid-await, update is dropped silently.
    • On @MainActor classes, Task {} inherits isolation — strong self is always safe.
    • The correct way to prevent a Task from keeping self alive: cancel in deinit.
    • Retained closures (timers, delegates) DO need [weak self] — but only in the closure.
      Guard once outside the Task, then pass strong self in. Never double-capture weakly.
    """)

    PlaygroundPage.current.finishExecution()
}
