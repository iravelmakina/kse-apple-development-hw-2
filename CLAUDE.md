# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A graded individual homework assignment (KSE "Apple Development" HW2), distributed as a
Swift Package template. The task: implement a bounded, deterministic concurrent task
processor using only the Swift standard library and XCTest (Apple's built-in unit-test
framework) — no third-party dependencies, no GCD, no locks, no UI, no networking.

`TASKS_AND_GRADES.md` is the **grading-authoritative contract**. Read it before changing
any code. It defines the exact public API (names, access levels, argument labels,
protocol conformances, return types) and the full acceptance matrix. Do not change public
signatures, and do not invent behavior that is not published there — grading explicitly
forbids relying on unpublished behavior.

## Commands

```bash
swift test                     # the sole required verification command
swift build                    # compile only
swift test --filter TaskProcessorSchedulingTests                         # one test class
swift test --filter TaskProcessorRetryTests/testSingleAttemptPolicyNeverRetries   # one method
```

Toolchain: `swift-tools-version: 6.0` (declared on the first line of `Package.swift`).
That selects Swift 6 language mode, where strict concurrency checking is on: passing a
value across a concurrency boundary that isn't provably safe to share (`Sendable`) is a
compile error, not a warning.

## Layout

Swift Package Manager (SwiftPM) fixes these paths by convention — `Package.swift` is the
manifest, `Sources/<TargetName>/` is production code, `Tests/<TargetName>Tests/` is tests.

- `Package.swift` — manifest: one library target `TaskProcessor`, one test target. Also
  declares minimum OS versions (macOS 10.15 / iOS 13), which is what makes `async`/`await`
  and actors available.
- `Sources/TaskProcessor/TaskProcessor.swift` — base implementation: `Job`, `JobOutcome`,
  `JobResult`, `TaskProcessorError`, and the `actor TaskProcessor`.
- `Sources/TaskProcessor/TaskProcessor+Retry.swift` — the optional bonus (`RetryPolicy`,
  `RetryPolicyError`, the second `process` overload). Kept separate so "additive, does not
  change the base API" is structural. Do not move base API into it.
- `Tests/TaskProcessorTests/TaskProcessorPublicTests.swift` — starter tests. **Do not
  edit or rename these**; renamed/copied starter methods do not count toward the required
  six student-authored tests.
- `Tests/TaskProcessorTests/TaskProcessorStudentTests.swift` — the student tests: shared
  helpers and test doubles at file scope, then seven focused `XCTestCase` classes, one per
  rubric category. SwiftPM compiles every `.swift` file under the target automatically.

## Current state

Complete. Both base members are implemented, the optional retry extension is in place,
and `swift test` passes 20 tests (5 starter + 15 student) in about 5 ms with no warnings
under Swift 6 strict concurrency. The template's original `fatalError("Implement
Homework 2")` stubs are gone.

## Architecture

The design the contract forces:

- `init(maximumConcurrency:)` validates eagerly; `process` runs a left-to-right preflight
  duplicate-ID scan and throws `.duplicateID(firstRepeatedID)` **before any worker runs**.
- Scheduling is a bounded window over `jobs` in input order: start at most
  `maximumConcurrency` workers, and when one finishes, start the next unstarted job
  (leftmost first). A `TaskGroup` plus an explicit index cursor is the natural fit.
- Results are stored **by input index**, not by completion order, so the returned array
  always mirrors `jobs` positionally and by ID regardless of who finishes first.
- Outcome mapping: return value → `.succeeded(n)`; ordinary `Error` → `.failed`;
  `CancellationError` → `.cancelled`. A single job failing never stops the others.
- Caller cancellation is observed *at the next scheduling decision*: cancel child work,
  start nothing new, mark every never-started job `.cancelled`, and keep outcomes that
  already completed. This is why cancellation must be checked in the scheduling loop, not
  only inside workers.

### Test style

Gate handshakes, not sleeps. The starter's `Gate` and the student file's `StudentGate`
both let the test decide exactly when each job starts and finishes, via
`wait(for:)` / `release(_:)` / `waitUntilStarted(for:)` / `waitUntilPassed(_:)`
(the starter's equivalent is named `waitUntilWaiting(for:)`). Never assert on elapsed
time, sleeps, or random input — graded behavior must be deterministic.

Two conventions worth preserving when adding tests:

- **Arrange-Act-Assert.** Capture mid-run observations into locals during Act and assert
  them at the end; never assert and then carry on acting.
- **Arm the watchdog** in any test that waits on a gate:
  `let watchdog = startWatchdog(on: gate); defer { watchdog.cancel() }`. `swift test` has
  no per-test timeout, so without it a wrong implementation hangs the suite forever
  instead of failing. It is cancelled on return and never fires on correct code.

### Optional bonus (+4)

A deterministic retry extension (`RetryPolicy`, `RetryPolicyError`, and a second
`process(_:retryPolicy:worker:)` overload whose worker also receives the attempt number)
is specified in `TASKS_AND_GRADES.md`. It is additive: it must not alter the base API.
Attempts are sequential inside the job's single concurrency slot — a retry must never
create an extra active job. No delay, backoff, or jitter.

## Non-code deliverables (graded, 2 of 12 points)

These are part of the assignment, not optional paperwork:

- `PLAN.md` — fill in the Approach and Risks sections; keep it current as the design changes.
- `AGENT_WORKLOG.md` — one row per agent interaction: tool/model, what was suggested,
  whether it was accepted/revised/rejected and why, and the evidence. **When you generate
  or change code here, update this table.** Never paste raw transcripts or secrets.
- `artifacts/` — optional, non-sensitive exported agent evidence. No minimum count.
- At least six distinct, student-authored XCTest methods beyond the starter tests.

`SUBMISSION.md` governs delivery: submit the public repo URL plus the full 40-character
SHA from `git rev-parse HEAD`. Never commit build output, secrets, or private data.

## Swift terms used above

- **actor** — a reference type whose mutable state is protected by the compiler: only one
  task touches it at a time, and calls from outside must `await`. Replaces a mutex here.
- **`Sendable`** — a marker protocol meaning "safe to pass between concurrent tasks".
- **`TaskGroup`** — structured concurrency primitive: spawn N child tasks, collect their
  results, and have the group's lifetime bound to the enclosing scope.
- **`CancellationError`** — the standard error thrown by cooperative code that notices its
  task was cancelled. Cancellation in Swift is a request, never a forced stop.
- **argument label** — the external parameter name at a call site. `init(maximumConcurrency:)`
  means the call reads `TaskProcessor(maximumConcurrency: 4)`. Labels are part of the
  function's identity, so renaming one breaks the published API.
- **`throws` / `try`** — Swift's error channel. `throws` on a signature, `try` at the call
  site, and errors propagate automatically instead of being returned alongside a value.
