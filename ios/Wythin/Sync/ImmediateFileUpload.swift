import Foundation
import UIKit

/// One bounded default-session transfer while the process has execution time.
/// Its owner retains the immutable file and its independent system upload.
@MainActor
final class ImmediateFileUpload {
    typealias Receipt = (HTTPURLResponse?, Data, Error?) -> Bool

    private struct Attempt {
        let batch: UUID
        let task: URLSessionUploadTask
        let progress: (Date) -> Void
        let receipt: Receipt
        let wake: () -> Void
        var observedStart = false
        var body = Data()
    }

    private let session: URLSession
    private let uptime: () -> TimeInterval
    private var attempt: Attempt?
    private var cancelledTasks = Set<Int>()
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var allowance: UIBackgroundTaskIdentifier = .invalid
    private var wakeTask: Task<Void, Never>?
    private var wakeAt: TimeInterval?
    private var afterCancellation: (() -> Void)?
    private var nextStartAt: TimeInterval = 0
    private var retryAt: TimeInterval = 0
    private var failures = 0

    init(configuration: URLSessionConfiguration = .default,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        let delegate = Delegate()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        delegate.owner = self
    }

    deinit {
        wakeTask?.cancel()
        session.invalidateAndCancel()
        let id = allowance
        if id != .invalid {
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
        }
    }

    func offer(batch: UUID, request: URLRequest, file: URL, notBefore: Date, now: Date,
               progress: @escaping (Date) -> Void = { _ in }, receipt: @escaping Receipt,
               wake: @escaping () -> Void) {
        guard attempt == nil else { return }
        if !cancelledTasks.isEmpty {
            afterCancellation = wake
            return
        }
        let instant = uptime()
        let delay = max(max(nextStartAt, retryAt) - instant, notBefore.timeIntervalSince(now))
        if delay > 0 {
            let due = instant + delay
            if let wakeAt, abs(wakeAt - due) < 0.05 { return }
            cancelWake()
            wakeAt = due
            wakeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.wakeAt = nil
                wake()
            }
            return
        }
        cancelWake()
        var request = request
        request.timeoutInterval = 20
        let task = session.uploadTask(with: request, fromFile: file)
        attempt = Attempt(batch: batch, task: task, progress: progress, receipt: receipt, wake: wake)
        nextStartAt = instant + 30
        allowance = UIApplication.shared.beginBackgroundTask(withName: "Deliver recording upload") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.attempt?.task === task else { return }
                self.recordFailure()
                self.cancel(batch: batch)
                wake()
            }
        }
        task.resume()
    }

    private func recordFailure() {
        failures = min(8, failures + 1)
        retryAt = uptime() + min(3600, 30 * pow(2, Double(failures - 1)))
    }

    func acknowledged(_ batch: UUID) {
        failures = 0
        retryAt = 0
        cancel(batch: batch)
    }

    func cancel(batch: UUID? = nil) {
        if batch == nil {
            cancelWake()
            afterCancellation = nil
        }
        guard let current = attempt, batch == nil || batch == current.batch else { return }
        attempt = nil
        cancelledTasks.insert(current.task.taskIdentifier)
        current.task.cancel()
        endAllowance()
    }

    func cancelAndWait() async {
        cancel()
        if !cancelledTasks.isEmpty {
            await withCheckedContinuation { cancellationWaiters.append($0) }
        }
    }

    private func endAllowance() {
        if allowance != .invalid {
            UIApplication.shared.endBackgroundTask(allowance)
            allowance = .invalid
        }
    }

    private func cancelWake() {
        wakeTask?.cancel()
        wakeTask = nil
        wakeAt = nil
    }

    private func observedStart(_ task: URLSessionTask, at date: Date) {
        guard attempt?.task === task, attempt?.observedStart == false else { return }
        attempt?.observedStart = true
        attempt?.progress(date)
    }

    private func finish(_ task: URLSessionTask, error: Error?) {
        if cancelledTasks.remove(task.taskIdentifier) != nil {
            if cancelledTasks.isEmpty {
                let waiting = cancellationWaiters
                cancellationWaiters.removeAll()
                for waiter in waiting { waiter.resume() }
                let wake = afterCancellation
                afterCancellation = nil
                wake?()
            }
            return
        }
        guard let current = attempt, current.task === task else { return }
        attempt = nil
        endAllowance()
        if current.receipt(task.response as? HTTPURLResponse, current.body, error) {
            acknowledged(current.batch)
        } else {
            recordFailure()
        }
        current.wake()
    }

    // The dedicated session serializes these callbacks on OperationQueue.main.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: ImmediateFileUpload?

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            MainActor.assumeIsolated {
                guard let owner, owner.attempt?.task === dataTask else { return }
                let remaining = 65_537 - (owner.attempt?.body.count ?? 0)
                owner.attempt?.body.append(data.prefix(remaining))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            if bytesSent > 0 { MainActor.assumeIsolated { owner?.observedStart(task, at: Date()) } }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            if let start = metrics.transactionMetrics.compactMap(\.requestStartDate).first {
                MainActor.assumeIsolated { owner?.observedStart(task, at: start) }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            MainActor.assumeIsolated { owner?.finish(task, error: error) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
