// PocketClient.swift — pocket-browser app侧
// 用法：
// let pocket = PocketClient(webView: yourWKWebView,
//                           serverURL: URL(string: "wss://…/pocket/ws")!,
//                           token: tokenFromKeychain)
// pocket.onStateChange = { connected in … }
// pocket.connect()
// 依赖：iOS 13+，无第三方库

import UIKit
import WebKit

final class PocketClient: NSObject {
    private let webView: WKWebView
    private let serverURL: URL
    private let token: String
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var retryDelay: TimeInterval = 1
    private var shouldReconnect = false

    private var pingTimer: Timer?
    private var pongPending = false
    private var pongDeadline: Date?

    var onStateChange: ((Bool) -> Void)?

    init(webView: WKWebView, serverURL: URL, token: String) {
        self.webView = webView
        self.serverURL = serverURL
        self.token = token
        super.init()
        NotificationCenter.default.addObserver(self,
            selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopPing()
    }

    func connect() {
        if task != nil {
            task?.cancel(with: .abnormalClosure, reason: nil)
            task = nil
        }
        shouldReconnect = true
        task = session.webSocketTask(with: authenticatedURL())
        task?.resume()
        retryDelay = 1
        receiveLoop()
        startPing()
        sendAppPing()
    }

    func disconnect() {
        shouldReconnect = false
        stopPing()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        onStateChange?(false)
    }

    @objc private func willEnterForeground() {
        guard shouldReconnect else { return }
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        stopPing()
        connect()
    }

    private func authenticatedURL() -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url!
    }

    // MARK: - Heartbeat

    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            self?.sendAppPing()
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
        pongPending = false
    }

    private func sendAppPing() {
        guard let task, task.state == .running else {
            handleDead()
            return
        }
        if pongPending, let deadline = pongDeadline, Date() > deadline {
            handleDead()
            return
        }
        pongPending = true
        pongDeadline = Date().addingTimeInterval(10)
        let msg = #"{"action":"heartbeat"}"#
        task.send(.string(msg)) { [weak self] error in
            if error != nil { self?.handleDead() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.pongPending else { return }
            self.handleDead()
        }
    }

    private func handleDead() {
        pongPending = false
        onStateChange?(false)
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        scheduleReconnect()
    }

    // MARK: - Receive

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg { self.handle(text) }
                self.receiveLoop()
            case .failure:
                self.onStateChange?(false)
                self.task = nil
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        stopPing()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - Command dispatch

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let type = cmd["type"] as? String, type == "heartbeat_ack" {
            pongPending = false
            onStateChange?(true)
            return
        }

        guard let id = cmd["id"] as? String,
              let action = cmd["action"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case "ping":
                self.reply(id: id, ok: true, result: "pong")
            case "goto":
                if let s = cmd["url"] as? String, let url = URL(string: s) {
                    self.webView.load(URLRequest(url: url))
                    self.reply(id: id, ok: true, result: "loading")
                } else { self.reply(id: id, ok: false, error: "bad url") }
            case "js":
                if let js = (cmd["js"] as? String) ?? (cmd["code"] as? String) {
                    self.webView.evaluateJavaScript(js) { value, error in
                        if let error { self.reply(id: id, ok: false, error: error.localizedDescription) }
                        else { self.reply(id: id, ok: true, result: String(describing: value ?? "")) }
                    }
                } else { self.reply(id: id, ok: false, error: "no js") }
            case "html":
                self.webView.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
                    self.reply(id: id, ok: true, result: value as? String ?? "")
                }
            case "screenshot":
                let cfg = WKSnapshotConfiguration()
                self.webView.takeSnapshot(with: cfg) { image, error in
                    if let png = image?.pngData() {
                        self.reply(id: id, ok: true, result: "data:image/png;base64," + png.base64EncodedString())
                    } else { self.reply(id: id, ok: false, error: error?.localizedDescription ?? "snapshot failed") }
                }
            default:
                self.reply(id: id, ok: false, error: "unknown action")
            }
        }
    }

    private func reply(id: String, ok: Bool, result: String? = nil, error: String? = nil) {
        var obj: [String: Any] = ["id": id, "ok": ok]
        if let result { obj["result"] = result }
        if let error { obj["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }
}
