//
//  The optional deterministic retry policy. Purely additive: nothing here
//  changes the base API in TaskProcessor.swift.
//

public struct RetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int

    public init(maximumAttempts: Int) throws {
        guard maximumAttempts > 0 else {
            throw RetryPolicyError.nonPositiveMaximumAttempts
        }

        self.maximumAttempts = maximumAttempts
    }
}

public enum RetryPolicyError: Error, Equatable {
    case nonPositiveMaximumAttempts
}

public extension TaskProcessor {
    /// Runs every job with the given retry policy.
    ///
    /// Retries live inside the job's single concurrency slot: the base scheduler
    /// sees one worker invocation per job, so attempts are sequential and a retry
    /// never creates an extra active job.
    func process(
        _ jobs: [Job],
        retryPolicy: RetryPolicy,
        worker: @escaping @Sendable (Job, Int) async throws -> Int
    ) async throws -> [JobResult] {
        try await process(jobs) { job in
            try await TaskProcessor.attempt(job, under: retryPolicy, worker: worker)
        }
    }
}

private extension TaskProcessor {
    /// Invokes `worker` until it succeeds or the policy's final attempt fails,
    /// numbering attempts from 1. `CancellationError` is surfaced immediately and
    /// never retried; there is no delay, backoff, or jitter between attempts.
    static func attempt(
        _ job: Job,
        under policy: RetryPolicy,
        worker: @Sendable (Job, Int) async throws -> Int
    ) async throws -> Int {
        var attempt = 1

        while true {
            do {
                return try await worker(job, attempt)
            } catch {
                if error is CancellationError {
                    throw error
                }

                guard attempt < policy.maximumAttempts else {
                    throw error
                }

                attempt += 1
            }
        }
    }
}
