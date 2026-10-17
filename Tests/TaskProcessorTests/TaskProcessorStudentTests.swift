import XCTest
@testable import TaskProcessor

// MARK: - Fixtures and helpers

/// Jobs in the given order, with 1-based inputs: the first ID gets input 1,
/// the second 2, and so on. Tests that assert on values derive them from this.
private func makeJobs(_ ids: String...) -> [Job] {
    ids.enumerated().map { Job(id: $1, input: $0 + 1) }
}

private func assertThrows<T, E: Error & Equatable>(
    _ expression: @autoclosure () throws -> T,
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertEqual(error as? E, expected, file: file, line: line)
    }
}

private func assertThrowsAsync<T, E: Error & Equatable>(
    _ expected: E,
    isolation: isolated (any Actor)? = #isolation,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected) to be thrown", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? E, expected, file: file, line: line)
    }
}

/// Fails the test, rather than hanging it forever, if the processor stops making
/// progress — for example by never starting a queued job, so that a
/// `waitUntilStarted` would otherwise block for good.
///
/// This is a watchdog, not a timing assertion: it is cancelled when the test
/// returns and can only fire on a broken implementation, so the passing path
/// stays entirely deterministic. Detached on purpose, so the XCTest runner
/// cannot starve it.
private func startWatchdog(
    on gate: StudentGate,
    seconds: Double = 5,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Task<Void, Never> {
    Task.detached {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        guard !Task.isCancelled else {
            return
        }

        XCTFail(
            "The processor made no further progress within \(seconds)s",
            file: file,
            line: line
        )
        await gate.abandon()
    }
}

private enum ProbeError: Error {
    case expected
    case workerShouldNotRun
}

// MARK: - Test doubles

/// Deterministic rendezvous between the test and the workers it schedules.
///
/// Each handshake is a flag for "already happened" plus a parking lot for
/// "has not happened yet", so the test never depends on timing.
private actor StudentGate {
    private var isOpen = false
    private var isAbandoned = false
    private var pendingReleases: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var startedIDs: Set<String> = []
    private var startObservers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var passedIDs: Set<String> = []
    private var passedObservers: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Order in which workers began, i.e. the scheduling order.
    private(set) var startOrder: [String] = []

    /// Called by a worker: announce arrival, then block until released.
    func wait(for id: String) async {
        noteStart(id)

        if isOpen || isAbandoned || pendingReleases.remove(id) != nil {
            markPassed(id)
            return
        }

        await withCheckedContinuation { continuation in
            waiters[id] = continuation
        }

        markPassed(id)
    }

    /// Called by the test: let one worker through, now or on arrival.
    func release(_ id: String) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume()
        } else {
            pendingReleases.insert(id)
        }
    }

    /// Opens the gate for good: every parked worker resumes and later waits pass
    /// straight through. Called after cancelling, so that an implementation which
    /// wrongly starts a queued job fails an assertion instead of parking a worker
    /// forever and deadlocking the suite.
    func openPermanently() {
        isOpen = true

        for waiter in waiters.values {
            waiter.resume()
        }

        waiters.removeAll()
    }

    /// Releases every parked continuation and lets all later waits through.
    /// Only the watchdog calls this: it exists so a processor that stops making
    /// progress fails the test instead of parking a worker forever.
    func abandon() {
        isAbandoned = true

        for waiter in waiters.values {
            waiter.resume()
        }
        waiters.removeAll()

        for observers in startObservers.values {
            observers.forEach { $0.resume() }
        }
        startObservers.removeAll()

        for observers in passedObservers.values {
            observers.forEach { $0.resume() }
        }
        passedObservers.removeAll()
    }

    func waitUntilStarted(for id: String) async {
        if isAbandoned || startedIDs.contains(id) {
            return
        }

        await withCheckedContinuation { continuation in
            startObservers[id, default: []].append(continuation)
        }
    }

    func waitUntilPassed(_ id: String) async {
        if isAbandoned || passedIDs.contains(id) {
            return
        }

        await withCheckedContinuation { continuation in
            passedObservers[id, default: []].append(continuation)
        }
    }

    func noteStart(_ id: String) {
        guard startedIDs.insert(id).inserted else {
            return
        }

        startOrder.append(id)

        for observer in startObservers.removeValue(forKey: id) ?? [] {
            observer.resume()
        }
    }

    private func markPassed(_ id: String) {
        passedIDs.insert(id)

        for observer in passedObservers.removeValue(forKey: id) ?? [] {
            observer.resume()
        }
    }
}

/// Tracks how many workers are inside their body at the same time.
private actor ConcurrencyProbe {
    private var active = 0
    private(set) var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func exit() {
        active -= 1
    }
}

/// Records the attempt numbers each job was invoked with.
private actor AttemptRecorder {
    private var recorded: [String: [Int]] = [:]

    /// Records an attempt and returns how many times this job has been invoked.
    @discardableResult
    func record(_ id: String, attempt: Int) -> Int {
        recorded[id, default: []].append(attempt)
        return recorded[id]?.count ?? 0
    }

    func attempts(for id: String) -> [Int] {
        recorded[id] ?? []
    }
}

// MARK: - Configuration and input validation

@MainActor
final class TaskProcessorValidationTests: XCTestCase {
    func testNegativeMaximumConcurrencyIsRejected() {
        assertThrows(
            try TaskProcessor(maximumConcurrency: -3),
            TaskProcessorError.nonPositiveMaximumConcurrency
        )
    }

    func testDuplicateIDReportsFirstRepeatedIDAndStartsNoWorker() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 4)
        let probe = ConcurrencyProbe()
        let jobs = makeJobs("a", "b", "c", "b", "a")

        await assertThrowsAsync(TaskProcessorError.duplicateID("b")) {
            try await processor.process(jobs) { _ in
                await probe.enter()
                throw ProbeError.workerShouldNotRun
            }
        }

        let workersStarted = await probe.peak

        XCTAssertEqual(workersStarted, 0, "A duplicate ID must abort before any worker runs")
    }
}

// MARK: - Bounded scheduling

@MainActor
final class TaskProcessorSchedulingTests: XCTestCase {
    func testActiveWorkerCountNeverExceedsMaximumConcurrency() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let gate = StudentGate()
        let watchdog = startWatchdog(on: gate)
        defer { watchdog.cancel() }

        let probe = ConcurrencyProbe()
        let jobs = makeJobs("a", "b", "c", "d", "e", "f")
        let ids = jobs.map(\.id)

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.enter()
                await gate.wait(for: job.id)
                await probe.exit()
                return job.input
            }
        }

        // Both parked at once, so the peak below is reached rather than assumed.
        await gate.waitUntilStarted(for: "a")
        await gate.waitUntilStarted(for: "b")

        for id in ids {
            await gate.release(id)
            await gate.waitUntilPassed(id)
        }

        let results = try await processing.value
        let peak = await probe.peak

        XCTAssertEqual(results.map(\.id), ids)
        XCTAssertEqual(peak, 2, "Two slots were used, and never more")
    }

    func testFreedSlotStartsTheNextJobInInputOrder() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = StudentGate()
        let watchdog = startWatchdog(on: gate)
        defer { watchdog.cancel() }

        let jobs = makeJobs("a", "b", "c")

        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.wait(for: job.id)
                return job.input * 2
            }
        }

        await gate.waitUntilStarted(for: "a")
        let orderWhileFirstIsBusy = await gate.startOrder

        await gate.release("a")
        await gate.waitUntilStarted(for: "b")
        await gate.release("b")
        await gate.waitUntilStarted(for: "c")
        await gate.release("c")

        let results = try await processing.value
        let startOrder = await gate.startOrder

        XCTAssertEqual(orderWhileFirstIsBusy, ["a"], "A limit of 1 allows only one job at a time")
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(2)),
                JobResult(id: "b", outcome: .succeeded(4)),
                JobResult(id: "c", outcome: .succeeded(6))
            ]
        )
        XCTAssertEqual(startOrder, ["a", "b", "c"], "A freed slot takes the leftmost unstarted job")
    }
}

// MARK: - Stable result ordering

@MainActor
final class TaskProcessorOrderingTests: XCTestCase {
    func testResultsKeepInputOrderWhenCompletionIsFullyReversed() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let gate = StudentGate()
        let watchdog = startWatchdog(on: gate)
        defer { watchdog.cancel() }

        let jobs = makeJobs("a", "b", "c")

        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.wait(for: job.id)
                return job.input * 100
            }
        }

        for id in ["a", "b", "c"] {
            await gate.waitUntilStarted(for: id)
        }

        for id in ["c", "b", "a"] {
            await gate.release(id)
            await gate.waitUntilPassed(id)
        }

        let results = try await processing.value
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(100)),
                JobResult(id: "b", outcome: .succeeded(200)),
                JobResult(id: "c", outcome: .succeeded(300))
            ]
        )
    }
}

// MARK: - Outcome handling

@MainActor
final class TaskProcessorOutcomeTests: XCTestCase {
    func testEachOutcomeIsMappedPerJobWhileOtherJobsContinue() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 4)
        let jobs = makeJobs("ok", "boom", "stopped", "ok-again")

        let results = try await processor.process(jobs) { job in
            switch job.id {
            case "boom":
                throw ProbeError.expected
            case "stopped":
                throw CancellationError()
            default:
                return job.input * 2
            }
        }

        XCTAssertEqual(
            results,
            [
                JobResult(id: "ok", outcome: .succeeded(2)),
                JobResult(id: "boom", outcome: .failed),
                JobResult(id: "stopped", outcome: .cancelled),
                JobResult(id: "ok-again", outcome: .succeeded(8))
            ]
        )
    }
}

// MARK: - Cooperative cancellation

@MainActor
final class TaskProcessorCancellationTests: XCTestCase {
    func testCancellationCancelsRunningAndNeverStartedJobs() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = StudentGate()
        let watchdog = startWatchdog(on: gate)
        defer { watchdog.cancel() }

        let jobs = makeJobs("a", "b", "c")

        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.noteStart(job.id)
                try Task.checkCancellation()
                await gate.wait(for: job.id)
                try Task.checkCancellation()
                return job.input
            }
        }

        await gate.waitUntilStarted(for: "a")
        processing.cancel()
        await gate.openPermanently()

        let results = try await processing.value
        let startOrder = await gate.startOrder

        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .cancelled),
                JobResult(id: "b", outcome: .cancelled),
                JobResult(id: "c", outcome: .cancelled)
            ]
        )
        XCTAssertEqual(startOrder, ["a"], "No queued job may start after cancellation")
    }

    func testResultsCompletedBeforeCancellationKeepTheirOutcome() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = StudentGate()
        let watchdog = startWatchdog(on: gate)
        defer { watchdog.cancel() }

        let jobs = makeJobs("done", "stopped")

        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.noteStart(job.id)
                try Task.checkCancellation()
                await gate.wait(for: job.id)
                try Task.checkCancellation()
                return job.input * 10
            }
        }

        await gate.waitUntilStarted(for: "done")
        await gate.release("done")

        // The second job starting proves the first one was collected successfully.
        await gate.waitUntilStarted(for: "stopped")
        processing.cancel()
        await gate.openPermanently()

        let results = try await processing.value
        XCTAssertEqual(
            results,
            [
                JobResult(id: "done", outcome: .succeeded(10)),
                JobResult(id: "stopped", outcome: .cancelled)
            ]
        )
    }
}

// MARK: - Optional extension: deterministic retry policy

@MainActor
final class TaskProcessorRetryTests: XCTestCase {
    func testNonPositiveMaximumAttemptsIsRejected() {
        assertThrows(
            try RetryPolicy(maximumAttempts: 0),
            RetryPolicyError.nonPositiveMaximumAttempts
        )
    }

    func testSingleAttemptPolicyNeverRetries() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 1)
        let recorder = AttemptRecorder()

        let results = try await processor.process(
            [Job(id: "one-shot", input: 1)],
            retryPolicy: policy
        ) { job, attempt in
            await recorder.record(job.id, attempt: attempt)
            throw ProbeError.expected
        }

        let attempts = await recorder.attempts(for: "one-shot")

        XCTAssertEqual(results, [JobResult(id: "one-shot", outcome: .failed)])
        XCTAssertEqual(attempts, [1], "maximumAttempts of 1 disables retrying")
    }

    func testRetryStopsAtTheFirstSuccessAndNumbersAttemptsFromOne() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 3)
        let recorder = AttemptRecorder()

        let results = try await processor.process(
            [Job(id: "recovers", input: 5)],
            retryPolicy: policy
        ) { job, attempt in
            await recorder.record(job.id, attempt: attempt)

            if attempt < 2 {
                throw ProbeError.expected
            }

            return job.input * attempt
        }

        let attempts = await recorder.attempts(for: "recovers")

        XCTAssertEqual(results, [JobResult(id: "recovers", outcome: .succeeded(10))])
        XCTAssertEqual(attempts, [1, 2], "Retrying must stop at the first success")
    }

    func testOrdinaryErrorOnTheFinalAttemptBecomesFailed() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let maximumAttempts = 3
        let policy = try RetryPolicy(maximumAttempts: maximumAttempts)
        let recorder = AttemptRecorder()

        let results = try await processor.process(
            [Job(id: "always-fails", input: 1)],
            retryPolicy: policy
        ) { job, attempt in
            await recorder.record(job.id, attempt: attempt)
            throw ProbeError.expected
        }

        let attempts = await recorder.attempts(for: "always-fails")

        XCTAssertEqual(results, [JobResult(id: "always-fails", outcome: .failed)])
        XCTAssertEqual(attempts, Array(1...maximumAttempts))
    }

    func testRetriesStayInsideTheJobConcurrencyLimit() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let maximumAttempts = 3
        let policy = try RetryPolicy(maximumAttempts: maximumAttempts)
        let probe = ConcurrencyProbe()
        let recorder = AttemptRecorder()
        let jobs = makeJobs("job-a", "job-b", "job-c", "job-d")

        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            await probe.enter()
            await recorder.record(job.id, attempt: attempt)
            let isFinalAttempt = attempt == maximumAttempts
            await probe.exit()

            if !isFinalAttempt {
                throw ProbeError.expected
            }

            return job.input
        }

        let peak = await probe.peak

        XCTAssertEqual(
            results,
            jobs.map { JobResult(id: $0.id, outcome: .succeeded($0.input)) }
        )
        XCTAssertLessThanOrEqual(peak, 2, "A retry must not create an extra active job")

        for job in jobs {
            let attempts = await recorder.attempts(for: job.id)
            XCTAssertEqual(attempts, Array(1...maximumAttempts), "Attempts for \(job.id)")
        }
    }
}

// MARK: - Retry policy under cancellation

@MainActor
final class TaskProcessorRetryCancellationTests: XCTestCase {
    func testCancellationErrorIsNeverRetried() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 4)
        let recorder = AttemptRecorder()

        let results = try await processor.process(
            [Job(id: "stopped", input: 1)],
            retryPolicy: policy
        ) { job, attempt in
            await recorder.record(job.id, attempt: attempt)
            throw CancellationError()
        }

        let attempts = await recorder.attempts(for: "stopped")

        XCTAssertEqual(results, [JobResult(id: "stopped", outcome: .cancelled)])
        XCTAssertEqual(attempts, [1], "CancellationError must never be retried")
    }

    func testCallerCancellationStopsRetriesAndQueuedJobs() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 4)
        let gate = StudentGate()
        let watchdog = startWatchdog(on: gate)
        defer { watchdog.cancel() }

        let recorder = AttemptRecorder()
        let jobs = makeJobs("retried", "queued")

        let processing = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                let call = await recorder.record(job.id, attempt: attempt)

                // Bail out before parking, so a job that is wrongly started after
                // cancellation fails an assertion instead of deadlocking the suite.
                try Task.checkCancellation()

                // Gate IDs are keyed on the invocation count rather than on the
                // attempt number, so this test cannot deadlock on an
                // implementation that numbers attempts incorrectly.
                await gate.wait(for: "\(job.id)#\(call)")
                try Task.checkCancellation()

                if call == 1 {
                    throw ProbeError.expected
                }

                return job.input
            }
        }

        // Let attempt 1 fail so the job moves on to attempt 2, then park there.
        await gate.waitUntilStarted(for: "retried#1")
        await gate.release("retried#1")
        await gate.waitUntilStarted(for: "retried#2")

        processing.cancel()
        await gate.openPermanently()

        let results = try await processing.value
        let retriedAttempts = await recorder.attempts(for: "retried")
        let queuedAttempts = await recorder.attempts(for: "queued")

        XCTAssertEqual(
            results,
            [
                JobResult(id: "retried", outcome: .cancelled),
                JobResult(id: "queued", outcome: .cancelled)
            ]
        )
        XCTAssertEqual(retriedAttempts, [1, 2], "A cancelled attempt must not be retried")
        XCTAssertEqual(queuedAttempts, [], "A queued job must not start after cancellation")
    }
}
