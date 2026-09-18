import SwiftUI
import WebKit

// Kept at the app root so changing tabs does not remove an active runtime.
struct AgentWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: UIViewType, context: Context) { }
}
