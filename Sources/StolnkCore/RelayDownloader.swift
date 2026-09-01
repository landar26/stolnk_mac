import Foundation

/**
 Streams one file's ciphertext out of the relay and into a `DecryptingSink`.

 The delegate callback decrypts and writes inline on a serial queue. That is
 deliberate: because the callback does not return until the bytes are on disk,
 URLSession will not hand over more, which gives backpressure for free. An
 `AsyncStream` in between would buffer unboundedly and let memory grow with
 download speed on a fast link.
 */
public final class RelayDownloader: NSObject, @unchecked Sendable {
	private final class State {
		var sink: DecryptingSink?
		var failure: Error?
		var continuation: CheckedContinuation<Void, Error>?
		var expectedStatus: Set<Int> = [200, 206]
	}

	private let lock = NSLock()
	private let state = State()
	private lazy var session: URLSession = {
		let queue = OperationQueue()
		queue.maxConcurrentOperationCount = 1
		let configuration = URLSessionConfiguration.default
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.timeoutIntervalForRequest = 60
		// A 20 GB file over a slow link is a legitimate case; the resource timeout
		// has to be generous or long transfers die for no reason.
		configuration.timeoutIntervalForResource = 24 * 60 * 60
		return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
	}()

	public override init() { super.init() }

	public func download(_ request: URLRequest, into sink: DecryptingSink) async throws {
		lock.withLock {
			state.sink = sink
			state.failure = nil
		}

		let task = session.dataTask(with: request)
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				lock.lock()
				state.continuation = continuation
				lock.unlock()
				task.resume()
			}
		} onCancel: {
			task.cancel()
		}
	}

	public func invalidate() {
		session.invalidateAndCancel()
	}

	private func finish(_ error: Error?) {
		lock.lock()
		let continuation = state.continuation
		state.continuation = nil
		let failure = state.failure ?? error
		state.sink = nil
		lock.unlock()

		guard let continuation else { return }
		if let failure {
			continuation.resume(throwing: failure)
		} else {
			continuation.resume()
		}
	}
}

extension RelayDownloader: URLSessionDataDelegate {
	public func urlSession(
		_ session: URLSession,
		dataTask: URLSessionDataTask,
		didReceive response: URLResponse,
		completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
	) {
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		lock.lock()
		let acceptable = state.expectedStatus.contains(status)
		if !acceptable {
			state.failure = APIError(
				status: status,
				code: "download_failed",
				message: "The relay returned \(status) for this file."
			)
		}
		lock.unlock()
		completionHandler(acceptable ? .allow : .cancel)
	}

	public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		lock.lock()
		let sink = state.sink
		let alreadyFailed = state.failure != nil
		lock.unlock()

		guard let sink, !alreadyFailed else { return }
		do {
			try sink.consume(data)
		} catch {
			lock.lock()
			state.failure = error
			lock.unlock()
			dataTask.cancel()
		}
	}

	public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		finish(error)
	}
}
