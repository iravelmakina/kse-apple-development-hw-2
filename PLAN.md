# Implementation Plan

Complete this before implementation and update it when the plan changes.

## Approach

`TaskProcessor` is an actor, so the scheduler's own bookkeeping needs no lock. One
`process` call runs in four phases.

**1. Preflight validation.** `init(maximumConcurrency:)` rejects a non-positive limit
immediately. `process` then scans `jobs` left to right into a `Set<String>` and throws
`.duplicateID` on the first job whose ID already appeared. The scan finishes before a
single task is spawned, so a duplicate list never runs a worker.

**2. Bounded scheduling.** A `withTaskGroup` holds the in-flight jobs. An index cursor
`next` walks the input array left to right: seed up to `maximumConcurrency` children,
then on every completion start the next unstarted job. The group can therefore never
hold more than the declared limit, and a slot freed by a completed job always goes to
the leftmost job that has not started.

**3. Indexed result storage.** Each child returns `(index: Int, outcome: JobOutcome)`.
Outcomes are written into a pre-sized `[JobOutcome?]` at the job's *input* index, never
appended in completion order. The final array is rebuilt by walking `jobs.indices`, so
the output has one entry per input job, in input order, with matching IDs — whatever
order the workers actually finished in. The `[JobOutcome?]` is declared inside the group
body and returned from it, so no mutable state is captured across an isolation boundary.

**4. Outcomes and cancellation.** A child maps its worker's result: a returned integer to
`.succeeded`, `CancellationError` to `.cancelled`, any other error to `.failed`. Children
never rethrow, so one failure cannot stop the rest and nothing escapes the group.
Cancellation is checked at each scheduling decision — seeding, and after every completion.
Once observed, the processor calls `cancelAll()` and stops starting work, but keeps
draining the group so results that already completed keep their outcome. Jobs that never
started are left `nil` and become `.cancelled` when the array is assembled. `process`
itself throws only for validation; a cancelled caller still receives a full results array.

The base scheduler lives in `Sources/TaskProcessor/TaskProcessor.swift`; the optional
bonus lives in `Sources/TaskProcessor/TaskProcessor+Retry.swift`, so the requirement that
it adds API without changing the base API is visible in the file layout.

**Optional retry extension.** `process(_:retryPolicy:worker:)` delegates to the base
`process`, putting the retry loop *inside* the closure it hands over. The scheduler
therefore still sees exactly one worker invocation per job, which makes the bonus rules
fall out for free: attempts are sequential, a retry cannot create an extra active job,
and input ordering plus every base cancellation rule are inherited unchanged.
`CancellationError` is rethrown immediately rather than retried; an ordinary error is
retried until a success or the final allowed attempt, whose error yields `.failed`.

## Milestones

- [x] Validate configuration and all job IDs before starting work.
- [x] Schedule jobs within the concurrency limit and preserve input order.
- [x] Map success, ordinary errors, and cancellation outcomes.
- [x] Handle caller cancellation and never-started jobs.
- [x] Add at least six distinct student-authored tests and run `swift test`.
- [x] Optional: deterministic retry policy extension.

## Risks and checks

**Draining the group after cancellation rather than breaking out.** Breaking would
discard children that had already finished, turning a completed `.succeeded` into
`.cancelled` and violating "results that completed before cancellation was observed keep
their outcome". Checked by `testResultsCompletedBeforeCancellationKeepTheirOutcome`,
which lets job one finish, then cancels while job two is parked, and asserts job one is
still `.succeeded(10)`.

**Assumption — retry during cancellation.** The bonus rules state they are exhaustive and
do not say that a pending retry must stop when the surrounding task is cancelled, so an
ordinary error is retried per the literal rule. This is safe in practice because a
cooperative worker throws `CancellationError` on the next attempt, which is never
retried and yields `.cancelled`.

**Timing dependence in the tests.** Concurrency tests that sleep are flaky and prove
nothing. Every test here drives scheduling through an explicit gate handshake
(`noteStart` / `wait` / `release` / `waitUntilStarted` / `waitUntilPassed`), so the test
decides exactly when each job starts and finishes. There is no `Task.sleep`, no
elapsed-time assertion, and no random input anywhere. `swift test` was run five times
with identical results.

**Tests that deadlock instead of failing.** The gate handshake makes the tests
deterministic, but it also means a wrong implementation can park a worker forever and
hang the suite instead of reporting a failure — and `swift test` has no per-test timeout,
so it would hang indefinitely. Four defences, each added after a mutation run actually
hung: workers record their start before they park; the cancellation tests call
`openPermanently()` after cancelling; the retry cancellation test keys its gate IDs on
invocation count rather than on the attempt number under test; and every gate-driven test
arms a detached 5-second watchdog that fails the test and calls `abandon()` on the gate,
which releases every parked continuation and lets all later waits fall through.

The watchdog is not a timing assertion. It is cancelled when the test returns and can
only fire on a broken implementation, so the passing path stays fully deterministic — the
suite still completes in about five milliseconds.

**Do the tests actually catch bugs?** Verified by mutation: twelve deliberate bugs were
introduced one at a time, including starting jobs after cancellation, storing results in
completion order, ignoring the concurrency limit, never freeing a slot, reporting the last
duplicate instead of the first, skipping validation entirely, marking never-started jobs
`.failed`, off-by-one in the attempt limit, numbering attempts from zero, and retrying
`CancellationError`. Ten were caught by at least one failing assertion, with no deadlocks,
and the suite returned to 20/20 after every revert.

Two mutants survive, and both are behaviour-preserving rather than untested: removing
`group.cancelAll()` (cancelling the caller already propagates to the group's children) and
removing the `jobs.isEmpty` early return (the general path returns `[]` for empty input
anyway). No test can distinguish either version, because there is no behavioural
difference to observe. Both lines are kept deliberately: each states a row of the
published contract — "cancels its child work" and "empty jobs returns `[]`" — in the place
a reader looks for it, and the source comments say they are explicit rather than
load-bearing.

**Workers must not serialise on the actor.** `process` is actor-isolated, so if the
per-job helper were isolated too, every worker would queue on the actor and the
concurrency limit would be meaningless for non-suspending work. The helper is a `static`
member, and `static` members of an actor are nonisolated — confirmed against the
compiler — so child tasks genuinely run off the actor.

**Test structure.** The tests follow the same conventions as my HW1 submission: seven
focused test classes rather than one large one, file-scope `makeJobs` fixture and
`assertThrows`/`assertThrowsAsync` helpers that forward `#filePath`/`#line` so failures
point at the calling test, and a `swift test` transcript exported to `artifacts/`.

**File-private starter helpers.** The starter's `Gate` is `private`, so it is invisible
to a new test file. The student tests define their own `StudentGate`, plus a
`ConcurrencyProbe` for peak-active-worker counts and an `AttemptRecorder` for the bonus
attempt numbers.
