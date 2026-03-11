//: # Lesson 10: Task Priority & `Task.yield()`
//:
//: **The nuance:** Swift's cooperative thread pool has a fixed number of threads
//: (roughly equal to CPU cores). CPU-bound tasks that never suspend can starve
//: higher-priority work — including UI updates.
//:
//: Two mechanisms to prevent this:
//: - `Task.yield()` — voluntarily suspend, letting the scheduler run other tasks
//: - Task priority — hints to the scheduler, NOT a guarantee of ordering
//:
//: Bonus nuance: *priority escalation* (sometimes called priority inheritance).
//: When a `.userInitiated` task `await`s the result of a `.background` task,
//: the runtime escalates the background task's priority to prevent priority inversion.
//:
//: **Real scenario:** A background search index that must not stall the UI,
//: even though it's doing heavy CPU work.

import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true

// MARK: - CPU-bound work, two versions

func buildIndex(documentCount: Int, cooperative: Bool) async -> Int {
    var totalChars = 0
    for i in 0..<documentCount {
        // Simulate per-document processing
        for _ in 0..<100 { totalChars += i.description.count }

        if cooperative && i % 200 == 0 {
            // ✅ Yield: suspend this task and let the scheduler run anything higher-priority
            await Task.yield()
        }
    }
    return totalChars
}

// MARK: - UI simulation: periodic "render frames"

func simulateUIUpdates(label: String, count: Int, intervalMs: Int) async {
    for i in 1...count {
        try? await Task.sleep(for: .milliseconds(intervalMs))
        print("  [UI \(label)] frame \(i) rendered")
    }
}

// MARK: - Demo 1: yielding vs. non-yielding competing with UI work

Task {
    print("=== Without yield: background work may starve UI ===\n")

    let start = Date()

    async let uiWork = simulateUIUpdates(label: "no-yield", count: 3, intervalMs: 50)
    async let bgWork = Task(priority: .background) {
        await buildIndex(documentCount: 2000, cooperative: false)
    }.value

    let (_, indexSize) = await (uiWork, bgWork)
    print("  Background indexed \(indexSize) chars in \(String(format: "%.2fs", Date().timeIntervalSince(start)))\n")

    print("=== With yield: background cooperates, UI stays responsive ===\n")

    let start2 = Date()

    async let uiWork2 = simulateUIUpdates(label: "yield   ", count: 3, intervalMs: 50)
    async let bgWork2 = Task(priority: .background) {
        await buildIndex(documentCount: 2000, cooperative: true)
    }.value

    let (_, indexSize2) = await (uiWork2, bgWork2)
    print("  Background indexed \(indexSize2) chars in \(String(format: "%.2fs", Date().timeIntervalSince(start2)))\n")
}

// MARK: - Demo 2: priority escalation

Task {
    try? await Task.sleep(for: .seconds(2)) // let demo 1 run first

    print("=== Priority escalation ===\n")

    let backgroundTask = Task(priority: .background) {
        print("  Background task starting at priority: \(Task.currentPriority)")
        // After escalation, this will run at higher priority
        try? await Task.sleep(for: .milliseconds(100))
        print("  Background task finishing at priority: \(Task.currentPriority)")
        return 42
    }

    // A high-priority task that needs the background task's result
    let userTask = Task(priority: .userInitiated) {
        print("  User task awaiting background result...")
        // Swift runtime sees a high-priority task waiting on a low-priority task.
        // It escalates the background task to prevent priority inversion.
        let result = await backgroundTask.value
        print("  User task got result: \(result)")
        print("  (Background task's priority was escalated to avoid blocking us)")
    }

    await userTask.value

    print("\nKey insights:")
    print("- yield() is voluntary preemption — call it in tight loops")
    print("- Priority is a hint, not a guarantee")
    print("- Priority escalation happens automatically when high-priority tasks await low-priority ones")

    PlaygroundPage.current.finishExecution()
}
