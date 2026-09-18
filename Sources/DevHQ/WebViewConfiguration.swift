import DevHQLua
import Foundation
import Lua

enum WebPublicURLAction: String, CaseIterable {
    case prompt
    case webview
    case system

    /// Accepts the DevHQ v1 spellings ("local webview", "system-browser", …).
    static func normalized(_ raw: String) -> WebPublicURLAction? {
        let value = raw.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
        return switch value {
        case "local", "local_webview", "web", "webview": .webview
        case "browser", "system_browser", "system": .system
        case "prompt": .prompt
        default: nil
        }
    }
}

/// A validated snapshot of the `config.webview` table.
struct WebViewConfiguration: Equatable {
    var openHTMLFiles = true
    var openLocalhostURLs = true
    var publicURLAction = WebPublicURLAction.prompt
    var homeURL = "about:blank"
    var localhostURL = "http://localhost:3000"
}

enum WebViewConfigurationError: LocalizedError, Equatable {
    case webviewMustBeTable
    case invalidBoolean(String)
    case invalidString(String)
    case invalidPublicURLAction

    var errorDescription: String? {
        switch self {
        case .webviewMustBeTable:
            "config.webview must be a table."
        case .invalidBoolean(let field):
            "config.webview.\(field) must be a boolean."
        case .invalidString(let field):
            "config.webview.\(field) must be a non-empty string."
        case .invalidPublicURLAction:
            "config.webview.public_url_action must be \"prompt\", \"webview\", or \"system\"."
        }
    }
}

enum WebViewLuaConfiguration {
    static func pushDefaultsTable(
        onto state: LuaPluginState,
        configuration: WebViewConfiguration = WebViewConfiguration()
    ) {
        state.newtable(nrec: 5)
        state.rawset(-1, utf8Key: "open_html_files", value: configuration.openHTMLFiles)
        state.rawset(-1, utf8Key: "open_localhost_urls", value: configuration.openLocalhostURLs)
        state.rawset(-1, utf8Key: "public_url_action", value: configuration.publicURLAction.rawValue)
        state.rawset(-1, utf8Key: "home_url", value: configuration.homeURL)
        state.rawset(-1, utf8Key: "localhost_url", value: configuration.localhostURL)
    }

    static func decode(from state: LuaPluginState) throws -> WebViewConfiguration {
        state.getglobal("config")
        defer { state.pop() }
        guard state.type(-1) == .table else {
            throw WebViewConfigurationError.webviewMustBeTable
        }
        state.rawget(-1, utf8Key: "webview")
        defer { state.pop() }
        if state.type(-1) == .nil { return WebViewConfiguration() }
        guard state.type(-1) == .table else {
            throw WebViewConfigurationError.webviewMustBeTable
        }

        let tableIndex = state.absindex(-1)
        var configuration = WebViewConfiguration()
        configuration.openHTMLFiles = try boolean(
            named: "open_html_files",
            from: state,
            at: tableIndex,
            fallback: configuration.openHTMLFiles
        )
        configuration.openLocalhostURLs = try boolean(
            named: "open_localhost_urls",
            from: state,
            at: tableIndex,
            fallback: configuration.openLocalhostURLs
        )
        configuration.publicURLAction = try publicURLAction(
            from: state,
            at: tableIndex,
            fallback: configuration.publicURLAction
        )
        configuration.homeURL = try string(
            named: "home_url",
            from: state,
            at: tableIndex,
            fallback: configuration.homeURL
        )
        configuration.localhostURL = try string(
            named: "localhost_url",
            from: state,
            at: tableIndex,
            fallback: configuration.localhostURL
        )
        return configuration
    }

    private static func boolean(
        named field: String,
        from state: LuaPluginState,
        at tableIndex: CInt,
        fallback: Bool
    ) throws -> Bool {
        state.rawget(tableIndex, utf8Key: field)
        defer { state.pop() }
        if state.type(-1) == .nil { return fallback }
        guard state.type(-1) == .boolean else {
            throw WebViewConfigurationError.invalidBoolean(field)
        }
        return state.toboolean(-1)
    }

    private static func string(
        named field: String,
        from state: LuaPluginState,
        at tableIndex: CInt,
        fallback: String
    ) throws -> String {
        state.rawget(tableIndex, utf8Key: field)
        defer { state.pop() }
        if state.type(-1) == .nil { return fallback }
        guard state.type(-1) == .string,
              let value = state.tostring(-1),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.utf8.contains(0) else {
            throw WebViewConfigurationError.invalidString(field)
        }
        return value
    }

    private static func publicURLAction(
        from state: LuaPluginState,
        at tableIndex: CInt,
        fallback: WebPublicURLAction
    ) throws -> WebPublicURLAction {
        state.rawget(tableIndex, utf8Key: "public_url_action")
        defer { state.pop() }
        if state.type(-1) == .nil { return fallback }
        guard state.type(-1) == .string,
              let value = state.tostring(-1),
              let action = WebPublicURLAction.normalized(value) else {
            throw WebViewConfigurationError.invalidPublicURLAction
        }
        return action
    }
}
