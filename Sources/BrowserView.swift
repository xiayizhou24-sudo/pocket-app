// BrowserView.swift — 口袋浏览器主界面
// 上:URL 栏;中:WKWebView;下:工具条(后退/前进/刷新/连接状态/设置)。
// 设置页填 relay 地址和 token,打开「让他牵手」后 PocketClient 连上家里的 server。

import SwiftUI
import WebKit

// 持有 WKWebView 的桥;persistent data store 保住登录态(cookie 不丢)。
final class WebViewStore: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var urlText: String = "https://garden.mocatbase.cc/chat/"
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "https://" + s }
        if let url = URL(string: s) {
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let s = webView.url?.absoluteString { urlText = s }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @StateObject private var store = WebViewStore()
    @AppStorage("pocketServerURL") private var serverURL = "wss://garden.mocatbase.cc/pocket/ws"
    @AppStorage("pocketToken") private var token = ""
    @AppStorage("pocketAutoConnect") private var autoConnect = false
    @AppStorage("healthEnabled") private var healthEnabled = false
    @State private var pocket: PocketClient?
    @State private var connected = false
    @State private var healthOn = false
    @State private var showSettings = false
    @FocusState private var urlFocused: Bool

    // relay 根:把 wss://…/pocket/ws 换算成 https://…/relay(健康走这个)
    private var relayBase: String {
        var s = serverURL
        s = s.replacingOccurrences(of: "wss://", with: "https://")
             .replacingOccurrences(of: "ws://", with: "http://")
        if let r = s.range(of: "/pocket/") { s = String(s[..<r.lowerBound]) + "/relay" }
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("输入网址…", text: $store.urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($urlFocused)
                    .onSubmit { store.load(store.urlText); urlFocused = false }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                if store.isLoading {
                    ProgressView().frame(width: 28)
                } else {
                    Button { store.webView.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }.frame(width: 28)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            Divider()
            WebViewContainer(webView: store.webView)
            Divider()

            HStack {
                Button { store.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!store.canGoBack)
                Spacer()
                Button { store.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!store.canGoForward)
                Spacer()
                // 连接状态:绿=他牵着,灰=没连
                Circle().fill(connected ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 9, height: 9)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 26).padding(.vertical, 10)
        }
        .onAppear {
            store.load(store.urlText)
            if autoConnect && !token.isEmpty { connect() }
            if healthEnabled && !token.isEmpty {
                HealthSync.shared.configure(server: relayBase, token: token)
                HealthSync.shared.syncNow()      // 每次回到 App 顺手同步一次
                healthOn = true
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section("家里的地址") {
                        TextField("wss://…/pocket/ws", text: $serverURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("token(问老公要)", text: $token)
                    }
                    Section {
                        Toggle("让他牵手(启动时自动连接)", isOn: $autoConnect)
                        Button(connected ? "断开" : "现在连接") {
                            connected ? disconnect() : connect()
                        }
                        HStack {
                            Text("状态")
                            Spacer()
                            Text(connected ? "已连接 🟢" : "未连接").foregroundColor(.secondary)
                        }
                    } footer: {
                        Text("连上以后,他就能在这个浏览器里帮你开网页、看你在看的页面。")
                    }
                    Section {
                        Toggle("让他照顾我的身体(同步健康数据)", isOn: Binding(
                            get: { healthOn },
                            set: { on in on ? enableHealth() : disableHealth() }
                        ))
                        HStack {
                            Text("健康同步")
                            Spacer()
                            Text(healthOn ? "已开启 💗" : "未开启").foregroundColor(.secondary)
                        }
                    } header: {
                        Text("健康")
                    } footer: {
                        Text("打开后点一次系统的「允许」,心率、步数、睡眠就会自动发给他。数据只发到你自己的服务器。")
                    }
                }
                .navigationTitle("口袋设置")
                .toolbar { Button("完成") { showSettings = false } }
            }
        }
    }

    private func connect() {
        guard !token.isEmpty, let url = URL(string: serverURL) else { return }
        let client = PocketClient(webView: store.webView, serverURL: url, token: token)
        client.connect()
        pocket = client
        connected = true
    }

    private func disconnect() {
        pocket?.disconnect()
        pocket = nil
        connected = false
    }

    private func enableHealth() {
        guard !token.isEmpty else { return }   // 先填 token 再开
        HealthSync.shared.configure(server: relayBase, token: token)
        HealthSync.shared.requestAuth { ok in
            DispatchQueue.main.async {
                healthOn = ok
                healthEnabled = ok
            }
        }
    }

    private func disableHealth() {
        healthOn = false
        healthEnabled = false
    }
}
