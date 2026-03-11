# Swift Concurrency Lesson Playground

## Project
- Path: /Users/elisawic/projs/swift_concurrency/MyPlayground.playground
- Target: iOS, Swift 6
- Structure: multi-page playground with Pages/ directory

## Lessons (10 pages)
1. `01-AsyncAwait-SequentialVsParallel` — async let vs sequential await; checkout example
2. `02-StructuredConcurrency-TaskTrees` — child task cancellation; search fan-out
3. `03-TaskGroup-DynamicConcurrency` — withTaskGroup vs withThrowingTaskGroup; batch upload
4. `04-Actors-Reentrancy` — TOCTOU reentrancy bug; cache with in-flight deduplication
5. `05-MainActor-Isolation` — actor isolation, thread hops, DispatchQueue.main.sync deadlock
6. `06-Sendable-TypeSystem` — struct/immutable class/@unchecked Sendable; concurrent enrichment
7. `07-AsyncSequence-Streams` — AsyncStream, delegate bridging, debounce operator
8. `08-Continuations-BridgingCallbacks` — withCheckedThrowingContinuation, common mistakes
9. `09-Cancellation-Cooperative` — Task.checkCancellation, withTaskCancellationHandler, onTermination
10. `10-TaskPriority-Yielding` — Task.yield(), priority escalation/inheritance

## Notes
- PlaygroundSupport "no such module" errors in SourceKit are false positives — normal outside Xcode
- Each page uses `PlaygroundPage.current.needsIndefiniteExecution = true` for async demos
- User preference: real-world examples over documentation samples
