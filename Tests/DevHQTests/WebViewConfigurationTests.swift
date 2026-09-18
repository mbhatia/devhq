import Foundation
import XCTest
@testable import DevHQ

final class WebViewConfigurationTests: XCTestCase {
    func testDefaults() {
        let configuration = WebViewConfiguration()
        XCTAssertTrue(configuration.openHTMLFiles)
        XCTAssertTrue(configuration.openLocalhostURLs)
        XCTAssertEqual(configuration.publicURLAction, .prompt)
        XCTAssertEqual(configuration.homeURL, "about:blank")
        XCTAssertEqual(configuration.localhostURL, "http://localhost:3000")
    }

    func testPublicURLActionAcceptsV1Aliases() {
        XCTAssertEqual(WebPublicURLAction.normalized("webview"), .webview)
        XCTAssertEqual(WebPublicURLAction.normalized("local webview"), .webview)
        XCTAssertEqual(WebPublicURLAction.normalized("Local-Webview"), .webview)
        XCTAssertEqual(WebPublicURLAction.normalized("web"), .webview)
        XCTAssertEqual(WebPublicURLAction.normalized("system"), .system)
        XCTAssertEqual(WebPublicURLAction.normalized("system browser"), .system)
        XCTAssertEqual(WebPublicURLAction.normalized("browser"), .system)
        XCTAssertEqual(WebPublicURLAction.normalized("prompt"), .prompt)
        XCTAssertNil(WebPublicURLAction.normalized("nope"))
        XCTAssertNil(WebPublicURLAction.normalized(""))
    }

    @MainActor
    func testConfigurationWithoutWebviewOverridesKeepsDefaults() throws {
        let host = try makeHost(script: "")
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        XCTAssertEqual(host.settings.webView, WebViewConfiguration())
    }

    @MainActor
    func testLuaOverridesAreDecodedAndValidated() throws {
        let host = try makeHost(script: """
        assert(type(config.webview) == "table")
        assert(config.webview.open_html_files == true)
        assert(config.webview.public_url_action == "prompt")
        config.webview.open_html_files = false
        config.webview.open_localhost_urls = false
        config.webview.public_url_action = "system browser"
        config.webview.home_url = "https://start.example"
        config.webview.localhost_url = "http://localhost:5173"
        """)
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        XCTAssertFalse(host.settings.webView.openHTMLFiles)
        XCTAssertFalse(host.settings.webView.openLocalhostURLs)
        XCTAssertEqual(host.settings.webView.publicURLAction, .system)
        XCTAssertEqual(host.settings.webView.homeURL, "https://start.example")
        XCTAssertEqual(host.settings.webView.localhostURL, "http://localhost:5173")
    }

    @MainActor
    func testReplacedWebviewTableFallsBackToDefaultsForMissingFields() throws {
        let host = try makeHost(script: """
        config.webview = { public_url_action = "webview" }
        """)
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        XCTAssertEqual(host.settings.webView.publicURLAction, .webview)
        XCTAssertTrue(host.settings.webView.openHTMLFiles)
        XCTAssertEqual(host.settings.webView.homeURL, "about:blank")
    }

    @MainActor
    func testInvalidPublicURLActionSurfacesPluginError() throws {
        let host = try makeHost(script: """
        config.webview.public_url_action = "carrier pigeon"
        """)
        host.loadUserConfiguration()

        XCTAssertTrue(
            host.settings.pluginError?.contains("public_url_action") == true,
            String(describing: host.settings.pluginError)
        )
        XCTAssertEqual(host.settings.webView, WebViewConfiguration())
    }

    @MainActor
    func testInvalidBooleanAndStringValuesSurfacePluginErrors() throws {
        let booleanHost = try makeHost(script: """
        config.webview.open_html_files = "yes"
        """)
        booleanHost.loadUserConfiguration()
        XCTAssertTrue(
            booleanHost.settings.pluginError?.contains("open_html_files") == true,
            String(describing: booleanHost.settings.pluginError)
        )
        XCTAssertTrue(
            booleanHost.settings.pluginError?.contains("boolean") == true,
            String(describing: booleanHost.settings.pluginError)
        )

        let stringHost = try makeHost(script: """
        config.webview.home_url = "   "
        """)
        stringHost.loadUserConfiguration()
        XCTAssertTrue(
            stringHost.settings.pluginError?.contains("home_url") == true,
            String(describing: stringHost.settings.pluginError)
        )

        let tableHost = try makeHost(script: """
        config.webview = "everything"
        """)
        tableHost.loadUserConfiguration()
        XCTAssertTrue(
            tableHost.settings.pluginError?.contains("config.webview must be a table") == true,
            String(describing: tableHost.settings.pluginError)
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeHost(script: String) throws -> LuaPluginHost {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(
            to: directory.appendingPathComponent("init.lua"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return LuaPluginHost(settings: EditorSettings(), configDirectory: directory)
    }
}
