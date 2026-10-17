public struct Job: Sendable, Equatable {
    public let id: String
    public let input: Int

    public init(id: String, input: Int) {
        self.id = id
        self.input = input
    }
}

public enum JobOutcome: Sendable, Equatable {
    case succeeded(Int)
    case failed
    case cancelled
}

public struct JobResult: Sendable, Equatable {
    public let id: String
    public let outcome: JobOutcome

    public init(id: String, outcome: JobOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

public enum TaskProcessorError: Error, Equatable {
    case nonPositiveMaximumConcurrency
    case duplicateID(String)
}

public actor TaskProcessor {
    private let maximumConcurrency: Int

    public init(maximumConcurrency: Int) throws {
        guard maximumConcurrency > 0 else {
            throw TaskProcessorError.nonPositiveMaximumConcurrency
        }

        self.maximumConcurrency = maximumConcurrency
    }

    /// Runs every job, keeping at most `maximumConcurrency` workers active.
    ///
    /// Results are returned in input order whatever order the workers finish in.
    /// Only invalid input throws: a duplicate ID aborts before any worker starts.
    /// A cancelled caller still receives a full result array.
    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        try TaskProcessor.validate(jobs)

        if jobs.isEmpty {
            return []
        }

        let outcomes = await TaskProcessor.schedule(
            jobs,
            limit: maximumConcurrency,
            worker: worker
        )

        // One result per job, in input order. A job that never started is cancelled.
        return zip(jobs, outcomes).map { job, outcome in
            JobResult(id: job.id, outcome: outcome ?? .cancelled)
        }
    }

    /// Runs `jobs` with at most `limit` workers active at a time, returning each
    /// outcome at its job's input index. A `nil` entry means the job never started,
    /// which only happens once cancellation has been observed.
    private static func schedule(
        _ jobs: [Job],
        limit: Int,
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async -> [JobOutcome?] {
        await withTaskGroup(
            of: (index: Int, outcome: JobOutcome).self
        ) { group in
            var collected = [JobOutcome?](repeating: nil, count: jobs.count)
            var next = 0
            var active = 0

            while true {
                // Top up to the limit, taking unstarted jobs left to right.
                // Once cancellation is observed, nothing new is started.
                while active < limit, next < jobs.count, !Task.isCancelled {
                    let index = next
                    let job = jobs[index]
                    group.addTask {
                        await TaskProcessor.run(job, at: index, worker: worker)
                    }
                    next += 1
                    active += 1
                }

                guard let finished = await group.next() else {
                    break
                }

                // Record before reacting to cancellation, so work that already
                // finished keeps the outcome it earned.
                collected[finished.index] = finished.outcome
                active -= 1

                // Explicit rather than load-bearing: cancelling the caller already
                // propagates to these children.
                if Task.isCancelled {
                    group.cancelAll()
                }
            }

            return collected
        }
    }

    /// Reports the first job whose ID appeared earlier, as the contract requires.
    private static func validate(_ jobs: [Job]) throws {
        var seen = Set<String>()

        for job in jobs {
            guard seen.insert(job.id).inserted else {
                throw TaskProcessorError.duplicateID(job.id)
            }
        }
    }

    private static func run(
        _ job: Job,
        at index: Int,
        worker: @Sendable (Job) async throws -> Int
    ) async -> (index: Int, outcome: JobOutcome) {
        do {
            let value = try await worker(job)
            return (index, .succeeded(value))
        } catch is CancellationError {
            return (index, .cancelled)
        } catch {
            return (index, .failed)
        }
    }
}
