import Foundation

// All mutable state lives on the main queue, including delegate callbacks.
final class GamepadClient: NSObject, URLSessionWebSocketDelegate {
    var onStatus: ((String, Bool) -> Void)?
    var onReset: (() -> Void)?
    private(set) var connected = false
    private var state = GamepadState()
    private var address: URL?
    private var socket: URLSessionWebSocketTask?
    private var timer: Timer?
    private var retry: DispatchWorkItem?
    private var sending = false
    private var pending = false
    private var sendStarted = Date.distantPast
    private var session: URLSession?

    func start(_ url: URL) {
        stop()
        address = url
        connect()
    }

    func stop() {
        address = nil
        retry?.cancel()
        retry = nil
        timer?.invalidate()
        timer = nil
        state = GamepadState()
        // Best effort immediate release; disconnect and the server's 0.5 s failsafe
        // also release inputs if iOS suspends us before this write completes.
        if connected { socket?.send(.string(state.message)) { _ in } }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        sending = false
        pending = false
        updateStatus("Disconnected", connected: false)
        onReset?()
    }

    func update(_ state: GamepadState) {
        guard connected else { return }
        self.state = state
        send()
    }

    private func connect() {
        guard let address else { return }
        state = GamepadState()
        onReset?()
        updateStatus("Connecting…", connected: false)
        if session == nil {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        }
        let task = session!.webSocketTask(with: address)
        socket = task
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        // The server sends no application messages. A pending read observes close
        // frames and network errors (URLSession handles ping/pong automatically).
        task.receive { [weak self, weak task] result in
            DispatchQueue.main.async {
                guard let self, let task, self.socket === task else { return }
                switch result {
                case .success: self.receive(task)
                case .failure(let error): self.failed(task, error: error)
                }
            }
        }
    }

    private func send() {
        guard connected, let task = socket else { return }
        // Coalesce fast touch events instead of queuing stale input on slow Wi-Fi.
        guard !sending else {
            pending = true
            if Date().timeIntervalSince(sendStarted) > 0.4 {
                failed(task, error: URLError(.timedOut))
            }
            return
        }
        sending = true
        pending = false
        sendStarted = Date()
        task.send(.string(state.message)) { [weak self, weak task] error in
            DispatchQueue.main.async {
                guard let self, let task, self.socket === task else { return }
                self.sending = false
                if let error { self.failed(task, error: error) }
                else if self.pending { self.send() }
            }
        }
    }

    private func failed(_ task: URLSessionWebSocketTask, error: Error?) {
        guard socket === task else { return }
        socket = nil
        task.cancel(with: .goingAway, reason: nil)
        timer?.invalidate()
        timer = nil
        sending = false
        pending = false
        state = GamepadState()
        onReset?()
        let detail = error?.localizedDescription ?? "Connection closed."
        updateStatus("Retrying — \(detail)", connected: false)
        guard address != nil else { return }
        let retry = DispatchWorkItem { [weak self] in self?.connect() }
        self.retry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
    }

    private func updateStatus(_ text: String, connected: Bool) {
        self.connected = connected
        onStatus?(text, connected)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard socket === webSocketTask else { return }
        updateStatus("Connected", connected: true)
        send()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.send() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        failed(webSocketTask, error: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let task = task as? URLSessionWebSocketTask { failed(task, error: error) }
    }
}
