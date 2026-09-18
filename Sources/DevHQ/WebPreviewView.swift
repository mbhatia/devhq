import SwiftUI
import WebKit

/// Hosts a web preview tab's WKWebView in the editor area.
struct WebPreviewView: NSViewRepresentable {
    @ObservedObject var tab: WebViewTab

    func makeNSView(context: Context) -> WKWebView {
        tab.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The tab strip button for a web preview tab, mirroring TerminalTabButton.
struct WebTabButton: View {
    @ObservedObject var tab: WebViewTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text(tab.title)
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected { Color.accentColor.frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help(tab.urlString)
    }
}
