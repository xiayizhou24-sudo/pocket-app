// PocketClient.swift — pocket-browser app侧参考实现
// 用法：
// let pocket = PocketClient(
//     webView: 你的WKWebView实例,
//     serverURL: URL(string: "wss://your-domain.example/pocket/ws")!,
//     token: tokenFromKeychain
// )
// pocket.connect()
// 依赖：iOS 13+，无第三方库

import WebKit

final class PocketClient: NSObject {
    private let webView: WKWebView
    private let serverURL: URL
    private let token: String
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var retryDelay: TimeInterval = 1
    private var shouldReconnect = false

    init(webView: WKWebView, serverURL: URL, token: String) {
        self.webView = webView
        self.serverURL = serverURL
        self.token = token
        super.init()
    }

    func connect() {
        guard task == nil else { return }
        shouldReconnect = true
        task = session.webSocketTask(with: authenticatedURL())
        task?.resume()
        retryDelay = 1
        receiveLoop()
    }

    func disconnect() {
        shouldReconnect = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func authenticatedURL() -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url!
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg { self.handle(text) }
                self.receiveLoop()                     // 继续收下一条
            case .failure:
                self.task = nil
                self.scheduleReconnect()               // 断线重连
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)           // 指数退避 封顶30s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - 指令分发

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = cmd["id"] as? String,
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
