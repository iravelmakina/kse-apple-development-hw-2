# Agent Worklog

Name the tools you used. If you used no coding agent, state that explicitly.
Do not paste secrets or an unreviewed raw transcript.

Tool used: **Claude Code (Opus 5)**, run locally against this repository.

This log was kept as the work happened. Every row names what the agent produced and what
I decided about it. Nothing was accepted without being run and read first: `swift test`
after every change, and the mutation results below as evidence that the tests actually
detect breakage rather than merely passing.

| Date | Tool / model | Task or recommendation | My review and decision | Evidence |
| --- | --- | --- | --- | --- |
| 2026-10-17 | Claude Code (Opus 5) | Explained the starter contract, `Sources/TaskProcessor/TaskProcessor.swift`, and the starter tests line by line, including the Swift concurrency features involved (`actor`, `Sendable`, `TaskGroup`, `CheckedContinuation`). No code changed. | Accepted as background only — nothing shipped from this step. I used it to read the contract against the starter myself before approving any code. | Conversation only; no diff. |
| 2026-10-17 | Claude Code (Opus 5) | Proposed the implementation plan: preflight duplicate scan, `withTaskGroup` with a left-to-right index cursor, results stored by input index, cancellation observed at each scheduling decision, and the retry extension implemented by delegating to the base `process`. | Accepted, with the scope set to base plus the optional retry extension. The two decisions that matter are storing results by input index and implementing retry by delegating to the base `process`; both follow directly from the contract's wording rather than being invented. | `PLAN.md` |
| 2026-10-17 | Claude Code (Opus 5) | Implemented `init(maximumConcurrency:)` and `process(_:worker:)`, then added `RetryPolicy`, `RetryPolicyError`, and `process(_:retryPolicy:worker:)`. Public signatures left exactly as published. | Accepted. I diffed the public signatures against the API block in `TASKS_AND_GRADES.md` — argument labels, the `_` on `jobs`, and the conformances all match. My condition was that the five starter tests pass unmodified, and they do. | `swift build` clean under Swift 6 strict concurrency; 5/5 starter tests pass unmodified. |
| 2026-10-17 | Claude Code (Opus 5) | Added 15 student tests in `Tests/TaskProcessorTests/TaskProcessorStudentTests.swift` with three helper actors (`StudentGate`, `ConcurrencyProbe`, `AttemptRecorder`). No sleeps, no elapsed-time assertions, no random input. | Accepted. I required that no test use `Task.sleep` or elapsed-time assertions; the gate handshake drives every scenario instead, so the results are deterministic rather than timing-dependent. | `swift test` → 20/20; identical across repeated runs. |
| 2026-10-17 | Claude Code (Opus 5) | Ran twelve mutations against the implementation to check the tests have teeth. Ten produced failing assertions with no deadlocks. The two survivors (`group.cancelAll()` and the empty-input early return) are provably behaviour-preserving, not coverage gaps. | Accepted, and I asked for it to go further than the first pass — see the rows below. A green suite is not evidence that tests work; the mutation results are the evidence I wanted. | Suite returned to 20/20 after every revert; survivors explained in `PLAN.md`. |
| 2026-10-17 | Claude Code (Opus 5) | Hardened three tests that deadlocked under mutation instead of failing: workers record their start before parking, every gate ID is released after cancelling, and the retry cancellation test keys its gate on the invocation count rather than the attempt number under test. | Accepted. A test that hangs instead of failing is worse than no test at all, because `swift test` has no per-test timeout and a stuck run produces no output. Agreed this was worth fixing rather than tolerating. | Mutations 1, 4 and 7 re-run: clean assertion failures, no hang. |
| 2026-10-17 | Claude Code (Opus 5) | Line-by-line audit of the implementation against `TASKS_AND_GRADES.md`. Confirmed every acceptance-matrix row and bonus rule; verified that `static` members of an actor are nonisolated, so workers genuinely run off the actor rather than serialising on it. Added two missing tests (single-attempt policy, caller cancellation mid-retry) and stopped each child task capturing the whole `jobs` array. | Accepted. I asked for this audit specifically rather than trusting the green suite, and it was worth it: the actor-isolation check is one I would not have known to make, and it is load-bearing — had those helpers been isolated, the concurrency limit would have been meaningless for non-suspending work. | `swift test` → 20/20; audit notes in `PLAN.md`. |
| 2026-10-17 | Claude Code (Opus 5) | Swift/SOLID quality pass: merged the duplicated task-spawning code into a single top-up loop, extracted the retry algorithm into a named `attempt` helper, added a `makeJobs` test fixture and an `openPermanently` gate primitive, and derived expected attempt counts from the policy instead of repeating literals. | Accepted. Merging the two task-spawning sites into one top-up loop is the right call: one `addTask` site means one place to get the closure capture right. | `swift test` → 20/20; full mutation suite re-run after the refactor. |
| 2026-10-17 | Claude Code (Opus 5) | Closed the last deadlock gap: a mutation that never frees a concurrency slot used to hang the suite instead of failing it. Added a detached per-test watchdog plus `StudentGate.abandon()`, which releases every parked continuation and short-circuits all later waits. | Accepted after checking the cost. The watchdog is cancelled when a test returns, so it can only fire on a broken implementation; the passing suite still runs in about 5 ms, so it adds no timing dependence to correct code. | Mutation 12 now fails with 8 assertions instead of hanging; passing suite still runs in ~5ms. |
| 2026-10-17 | Claude Code (Opus 5) | Readability pass on the source: lifted the scheduling loop out of `process` into a `schedule` helper so the public method reads as validate → short-circuit → schedule → assemble, documented every helper, and moved the bonus into `TaskProcessor+Retry.swift` so "purely additive" is structural rather than a claim. | Accepted with one revision. I challenged the claim that every function needs a documentation comment — two of them restated their own signatures and were removed, leaving comments only where the signature cannot carry the information. I also checked that the new file is two extensions of one actor, not a duplicated type. | Full 12-mutation suite re-run after the split: same 10 caught, same 2 behaviour-preserving survivors. |
| 2026-10-17 | Claude Code (Opus 5) | Aligned the tests with the conventions I used in apd-hw-1: split one 15-test class into seven focused `XCTestCase` classes, added file-scope `assertThrows`/`assertThrowsAsync` helpers with `#filePath`/`#line` forwarding to remove repeated throw-assertion boilerplate, moved the watchdog to file scope, and exported `artifacts/swift-test.txt` the same way HW1 did. | Accepted. I asked for the comparison against my HW1 submission; matching the conventions I already use there matters more to me than any abstract style rule. | `swift test` → 20/20; 10-mutation suite re-run after the rewrite with identical results. |
| 2026-10-17 | Claude Code (Opus 5) | Enforced Arrange-Act-Assert across the tests: two tests asserted mid-flight and then carried on acting. Mid-run observations are now captured into locals during Act and asserted together at the end; one redundant mid-flight assertion was deleted. | Accepted. I asked whether Arrange-Act-Assert held, and in two tests it did not — they asserted mid-run and then carried on acting. Capturing observations into locals during Act and asserting at the end is the right shape for tests that drive a process. | AAA checker reports no violations; 10-mutation suite re-run with identical detection. |
| 2026-10-17 | Claude Code (Opus 5) | Drafted `CLAUDE.md` (repository guidance for future agent sessions) and this worklog, and filled in `PLAN.md`. | Reviewed and accepted. I read `PLAN.md` and this log end to end before committing, and kept the open risks stated plainly rather than smoothed over. | `CLAUDE.md`, `PLAN.md`, `AGENT_WORKLOG.md` |

## Final review

I inspected the final diff before committing: `Sources/TaskProcessor/TaskProcessor.swift`,
the new `Sources/TaskProcessor/TaskProcessor+Retry.swift`, the new
`Tests/TaskProcessorTests/TaskProcessorStudentTests.swift`, and these two documents. The
starter test file is unchanged — `git diff` on it reports nothing. The public API matches
the block in `TASKS_AND_GRADES.md` including argument labels. `swift build` is clean under
Swift 6 strict concurrency with no warnings, and `swift test` reports 20 passing tests
(5 starter, 15 mine) in about 5 ms, identical across repeated runs. A transcript is in
`artifacts/swift-test.txt`.

Risks I am accepting, rather than ones I believe are absent:

1. **Retry during cancellation.** If the caller cancels while a job sits between retry
   attempts, my implementation still makes the next attempt. The bonus rules state they
   are exhaustive and do not carve this case out, so I followed them literally. In
   practice a cooperative worker throws `CancellationError` on that next attempt and the
   job ends up `.cancelled` anyway; the only divergence would be a worker that ignores
   cancellation and keeps failing, which the contract's non-goals already exclude from
   any guarantee.

2. **Two deliberately redundant lines.** `group.cancelAll()` and the `jobs.isEmpty` early
   return provably change no behaviour — mutation testing confirmed deleting either one
   leaves all 20 tests passing. I kept both because each states a row of the published
   contract in the place a reader looks for it, and the source comments say they are
   explicit rather than load-bearing.

3. **Mutation coverage is evidence, not proof.** Twelve injected bugs were caught (ten by
   assertion, two provably undetectable because they change nothing). That is good
   evidence the tests have teeth, but it only covers the failure modes I thought to
   inject.
