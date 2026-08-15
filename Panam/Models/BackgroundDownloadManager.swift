//
//  BackgroundDownloadManager.swift
//  Panam
//

import Foundation

/// Runs GmailFetcher.downloadAttachment's GET through a background
/// URLSession instead of URLSession.shared, so a statement PDF download iOS
/// started while Panam was in the foreground keeps going — handed off to
/// the system's own transfer daemon — if the app gets backgrounded and then
/// suspended partway through. A plain URLSession.shared task is cancelled
/// the moment the app suspends; a background-configured one isn't.
///
/// Bridges the delegate-callback shape URLSessionDownloadDelegate requires
/// back to plain async/await via one CheckedContinuation per in-flight
/// task, keyed by taskIdentifier — every existing call site
/// (EmailFetchCoordinator's processRow/runStatementFetch) already just
/// `await`s GmailFetcher.downloadAttachment(...), so nothing about how
/// those call sites are written has to change: the same await simply
/// resumes whenever the download actually finishes, whether that's a
/// second later in the foreground or after iOS briefly wakes a suspended
/// Panam to deliver the result. That resumption — the awaiting Task
/// picking back up mid-pipeline (extract → reconcile → notify) — *is* how
/// EmailFetchCoordinator finds out a background download finished; there's
/// no separate notify-the-coordinator step to wire up.
///
/// One real limitation: this only carries a download across *suspension*,
/// not termination. If iOS fully kills the process (jetsam, or the user
/// force-quits) while a download is still in flight, the Task holding that
/// continuation dies with it — there's no live call frame left to resume
/// into. handleEventsForBackgroundURLSession (see PanamAppDelegate) still
/// gets the OS's required wake-and-acknowledge callback in that case, and
/// backgroundCompletionHandler below is called as documented, but the
/// original fetch's in-progress reconciliation work is gone, same as if
/// the fetch had never started. That's the scenario the on-device Apple
/// Intelligence model and Gmail API calls throughout this app already
/// assume doesn't need to survive — "backgrounded, not force-quit," per
/// how this feature was specified.
final class BackgroundDownloadManager: NSObject {
    static let shared = BackgroundDownloadManager()

    static let sessionIdentifier = "enric.Plush.statementAttachmentDownload"

    /// Set by PanamAppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)
    /// when iOS relaunches/wakes Panam specifically to deliver background
    /// session events. Apple requires this be called once every event for
    /// that session has been delivered (urlSessionDidFinishEvents below) —
    /// it's how the app tells the system "I'm done processing what you
    /// woke me up for," letting iOS re-suspend it and update the
    /// background-refresh snapshot rather than assuming the app hung.
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // A statement PDF is small enough, and the point of this session
        // is exactly to keep going when the user isn't staring at a
        // progress bar, so there's no reason to require Wi-Fi only.
        configuration.allowsCellularAccess = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Guards pendingContinuations — URLSessionDownloadDelegate callbacks
    /// land on URLSession's own delegate queue (a background queue, not
    /// necessarily serialized with respect to callers of download(_:)), so
    /// the dictionary needs its own lock rather than relying on actor
    /// isolation (URLSessionDelegate requires NSObjectProtocol conformance,
    /// which rules out making this type an actor).
    private let lock = NSLock()
    private var pendingContinuations: [Int: CheckedContinuation<Data, Error>] = [:]

    private override init() { super.init() }

    /// Same contract as GmailFetcher's private get(_:accessToken:) — an
    /// authenticated GET returning the raw response body, or throwing
    /// GmailFetchError.http for a non-2xx status. downloadAttachment is the
    /// only caller; every other GmailFetcher request stays on
    /// URLSession.shared; a small/fast metadata call has nothing to gain
    /// from background-session overhead, and background sessions don't
    /// support ordinary in-memory data tasks anyway — only download/upload
    /// tasks, which is why this reads the response back from a temp file
    /// rather than accumulating Data like URLSession.shared.data(for:) does.
    func download(_ url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            lock.lock()
            pendingContinuations[task.taskIdentifier] = continuation
            lock.unlock()
            task.resume()
        }
    }

    private func resume(taskIdentifier: Int, with result: Result<Data, Error>) {
        lock.lock()
        let continuation = pendingContinuations.removeValue(forKey: taskIdentifier)
        lock.unlock()
        continuation?.resume(with: result)
    }
}

extension BackgroundDownloadManager: URLSessionDownloadDelegate {
    /// Fires only on success. The file at `location` is a temp file iOS
    /// deletes the instant this method returns, so the read has to happen
    /// synchronously right here — nothing async, nothing deferred.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = (try? Data(contentsOf: location)).flatMap { String(data: $0, encoding: .utf8) } ?? "unknown error"
            resume(taskIdentifier: downloadTask.taskIdentifier, with: .failure(GmailFetchError.http(http.statusCode, body)))
            return
        }
        guard let data = try? Data(contentsOf: location) else {
            resume(taskIdentifier: downloadTask.taskIdentifier, with: .failure(GmailFetchError.decoding))
            return
        }
        resume(taskIdentifier: downloadTask.taskIdentifier, with: .success(data))
    }

    /// Fires for every task on completion, success or failure — but a
    /// successful download was already resumed (and its continuation
    /// removed) by didFinishDownloadingTo above, so this only ever has
    /// something to do when error is non-nil: a network failure, a
    /// cancellation, or the transfer never reaching the success callback
    /// at all.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        resume(taskIdentifier: task.taskIdentifier, with: .failure(error))
    }

    /// Required acknowledgement after iOS wakes/relaunches Panam to deliver
    /// a background session's results (see PanamAppDelegate) — must be
    /// called on the main queue per Apple's documentation.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
