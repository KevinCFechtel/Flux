import Foundation
import XCTest
@testable import FluxNews

final class AppleCoreExecutionTests: XCTestCase {
    @MainActor
    func testResponsiveWorkRunsOffMainActorThread() async throws {
        let execution = AppleCoreExecution(responsiveConcurrency: 1, blockingConcurrency: 1)

        XCTAssertTrue(Thread.isMainThread)
        let operationWasOnMainThread = try await execution.responsive { Thread.isMainThread }

        XCTAssertFalse(operationWasOnMainThread)
    }

    func testResponsiveWorkIsBounded() async throws {
        let execution = AppleCoreExecution(responsiveConcurrency: 2, blockingConcurrency: 1)
        let gate = ExecutionGate()
        let tasks = (0 ..< 4).map { _ in
            Task { try await execution.responsive { gate.enter(); return 1 } }
        }

        try gate.waitForStarts(2)
        XCTAssertEqual(gate.startCount, 2)
        gate.release(2)
        try gate.waitForStarts(2)
        XCTAssertEqual(gate.maximumConcurrentOperations, 2)
        gate.release(2)
        for task in tasks { _ = try await task.value }
    }

    func testBlockingWorkIsBounded() async throws {
        let execution = AppleCoreExecution(responsiveConcurrency: 1, blockingConcurrency: 2)
        let gate = ExecutionGate()
        let tasks = (0 ..< 4).map { _ in
            Task { try await execution.blocking { gate.enter(); return 1 } }
        }

        try gate.waitForStarts(2)
        XCTAssertEqual(gate.startCount, 2)
        gate.release(2)
        try gate.waitForStarts(2)
        XCTAssertEqual(gate.maximumConcurrentOperations, 2)
        gate.release(2)
        for task in tasks { _ = try await task.value }
    }

    func testBlockingWorkDoesNotBlockResponsiveWork() async throws {
        let execution = AppleCoreExecution(responsiveConcurrency: 1, blockingConcurrency: 1)
        let blockingGate = ExecutionGate()
        let responsiveStarted = DispatchSemaphore(value: 0)
        let blockingTask = Task { try await execution.blocking { blockingGate.enter(); return 1 } }

        try blockingGate.waitForStarts(1)
        let responsiveTask = Task {
            try await execution.responsive {
                responsiveStarted.signal()
                return 2
            }
        }

        XCTAssertEqual(responsiveStarted.wait(timeout: .now() + 2), .success)
        blockingGate.release(1)
        let blockingValue = try await blockingTask.value
        let responsiveValue = try await responsiveTask.value
        XCTAssertEqual(blockingValue, 1)
        XCTAssertEqual(responsiveValue, 2)
    }

    func testValuesAndErrorsPropagateUnchanged() async throws {
        let execution = AppleCoreExecution(responsiveConcurrency: 1, blockingConcurrency: 1)

        let value = try await execution.responsive { 42 }
        XCTAssertEqual(value, 42)
        do {
            _ = try await execution.blocking { throw ExpectedError.expected }
            XCTFail("Expected Core error")
        } catch let error as ExpectedError {
            XCTAssertEqual(error, .expected)
        }
    }

    func testCancelledQueuedWorkDoesNotRunAndDoesNotLeakCapacity() async throws {
        let execution = AppleCoreExecution(responsiveConcurrency: 1, blockingConcurrency: 1)
        let gate = ExecutionGate()
        let first = Task { try await execution.blocking { gate.enter(); return 1 } }
        try gate.waitForStarts(1)

        let ranCancelledOperation = LockedFlag()
        let cancelled = Task {
            try await execution.blocking {
                ranCancelledOperation.set()
                return 2
            }
        }
        cancelled.cancel()
        gate.release(1)

        let firstValue = try await first.value
        XCTAssertEqual(firstValue, 1)
        do {
            _ = try await cancelled.value
            XCTFail("Expected queued work cancellation")
        } catch is CancellationError {
            // Expected: cancellation prevented the queued Core closure from starting.
        }
        XCTAssertFalse(ranCancelledOperation.value)
        let followUp = try await execution.blocking { 3 }
        XCTAssertEqual(followUp, 3)
    }

    func testFailuresAndCancellationsLeaveBothLanesUsable() async throws {
        let execution = AppleCoreExecution(responsiveConcurrency: 1, blockingConcurrency: 1)

        for _ in 0 ..< 3 {
            do {
                _ = try await execution.responsive { throw ExpectedError.expected }
                XCTFail("Expected Core error")
            } catch let error as ExpectedError {
                XCTAssertEqual(error, .expected)
            }
        }

        let gate = ExecutionGate()
        let first = Task { try await execution.blocking { gate.enter(); return 1 } }
        try gate.waitForStarts(1)
        let cancelled = Task { try await execution.blocking { 2 } }
        cancelled.cancel()
        gate.release(1)
        _ = try await first.value
        _ = try? await cancelled.value

        let responsiveValue = try await execution.responsive { 4 }
        let blockingValue = try await execution.blocking { 5 }
        XCTAssertEqual(responsiveValue, 4)
        XCTAssertEqual(blockingValue, 5)
    }

    func testSynchronousIOSCoreCallSitesUseTheCentralExecutionBoundary() throws {
        let iosDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = try [
            "FluxNews/NewsreaderStore.swift",
            "FluxNews/IOSSearchStore.swift",
            "FluxNews/CoreBootstrapper.swift"
        ].map { try String(contentsOf: iosDirectory.appendingPathComponent($0), encoding: .utf8) }

        for source in sources {
            XCTAssertFalse(source.contains("Task.detached"))
            XCTAssertTrue(source.contains("AppleCoreExecution.shared"))
        }

        XCTAssertTrue(sources[0].contains("responsiveResult {\n                try core.navigationProjection"))
        XCTAssertTrue(sources[0].contains("blockingResult { try core.sync"))
        XCTAssertTrue(sources[0].contains("blockingResult { try loader(feedID, variant)"))
        XCTAssertTrue(sources[0].contains("responsiveResult { try core.setReadStateBulk(articleIds: ids, read: true)"))
        XCTAssertTrue(sources[1].contains("blockingResult {\n                try core.searchArticles"))
        XCTAssertTrue(sources[1].contains("blockingResult { try core.readerDocumentForSearch"))
        XCTAssertTrue(sources[2].contains("blockingResult {\n            try validator(proposed)"))
    }
}

private enum ExpectedError: Error, Equatable, Sendable {
    case expected
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ExecutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var activeOperations = 0
    private var starts = 0
    private var maximumActiveOperations = 0

    func enter() {
        lock.lock()
        starts += 1
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        lock.unlock()
        started.signal()
        releaseSemaphore.wait()
        lock.lock()
        activeOperations -= 1
        lock.unlock()
    }

    func waitForStarts(_ count: Int, timeout: TimeInterval = 2) throws {
        for _ in 0 ..< count {
            guard started.wait(timeout: .now() + timeout) == .success else {
                throw GateError.timedOut
            }
        }
    }

    func release(_ count: Int) {
        for _ in 0 ..< count { releaseSemaphore.signal() }
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var maximumConcurrentOperations: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveOperations
    }
}

private enum GateError: Error {
    case timedOut
}
