import Foundation
import XCTest
@testable import GingerCore

final class CoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func script(in directory: URL, name: String = "test", body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testDiscoveryAndSettings() throws {
        let store = ConfigurationStore(directory: try temporaryDirectory())
        try store.prepare()
        _ = try script(in: store.scriptsDirectory, name: "hello", body: "echo Hello")
        var config = try store.load()
        XCTAssertEqual(config.widgets.map(\.id), ["hello"])
        config.widgets[0].enabled = false
        config.widgets[0].displaySeconds = 7
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
        try FileManager.default.removeItem(at: store.scriptsDirectory.appendingPathComponent("hello"))
        XCTAssertEqual(try store.load(), config)
        XCTAssertFalse(store.scriptExists("hello"))
    }

    func testFirstLaunchDoesNotInstallWidgets() throws {
        let store = ConfigurationStore(directory: try temporaryDirectory())
        XCTAssertTrue(try store.load().widgets.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.scriptsDirectory.path).isEmpty)
    }

    func testBadConfigurationIsNotOverwritten() throws {
        let store = ConfigurationStore(directory: try temporaryDirectory())
        try store.prepare()
        let data = Data("not JSON".utf8)
        try data.write(to: store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.file), data)
        XCTAssertThrowsError(try Configuration(widgets: [.init(id: "../bad")]).validate())
        XCTAssertThrowsError(try Configuration(widgets: [.init(id: "x"), .init(id: "x")]).validate())
        XCTAssertThrowsError(try Configuration(widgets: [.init(id: "x", refreshSeconds: 0)]).validate())
    }

    func testMissingSettingsUseDefaults() throws {
        let config = try JSONDecoder().decode(Configuration.self,
            from: Data(#"{"widgets":[{"id":"hello"}]}"#.utf8))
        XCTAssertEqual(config.widgets[0], WidgetConfiguration(id: "hello"))
    }

    func testRotationUsesEachDurationAndSkipsDisabledWidgets() {
        var rotation = Rotation()
        let start = Date(timeIntervalSince1970: 0)
        let widgets: [WidgetConfiguration] = [
            .init(id: "a", displaySeconds: 3), .init(id: "off", enabled: false),
            .init(id: "b", displaySeconds: 5)
        ]
        XCTAssertEqual(rotation.update(widgets: widgets, now: start), "a")
        XCTAssertEqual(rotation.update(widgets: widgets, now: start.addingTimeInterval(2)), "a")
        XCTAssertEqual(rotation.update(widgets: widgets, now: start.addingTimeInterval(3)), "b")
        XCTAssertEqual(rotation.update(widgets: widgets, now: start.addingTimeInterval(7)), "b")
        XCTAssertEqual(rotation.update(widgets: widgets, now: start.addingTimeInterval(8)), "a")
        XCTAssertEqual(rotation.update(widgets: [widgets[2]], now: start.addingTimeInterval(99)), "b")
        XCTAssertEqual(rotation.update(widgets: [widgets[2]], now: start.addingTimeInterval(999)), "b")
        XCTAssertNil(rotation.update(widgets: [], now: start))
    }

    func testScriptOutputAndEnvironment() async throws {
        let dir = try temporaryDirectory()
        let url = try script(in: dir, body: "printf '%s\\nDetail\\n' \"$GREETING\"")
        let result = try await ScriptRunner.run(script: url, directory: dir,
                                                environment: ["GREETING": "Hello 🌧️"])
        XCTAssertEqual(result.title, "Hello 🌧️")
        XCTAssertEqual(result.detail, "Hello 🌧️\nDetail")
    }

    func testScriptFailureEmptyOutputAndTimeout() async throws {
        let dir = try temporaryDirectory()
        for body in ["echo Problem >&2; exit 1", "exit 0", "exec sleep 5"] {
            let url = try script(in: dir, body: body)
            do {
                _ = try await ScriptRunner.run(script: url, directory: dir,
                                                environment: [:], timeout: 0.1)
                XCTFail("Expected a script error.")
            } catch { XCTAssertTrue(error is GingerError) }
        }
    }

    func testTimeoutStopsChildProcesses() async throws {
        let dir = try temporaryDirectory()
        let url = try script(in: dir, body:
            "/bin/sh -c 'trap \"\" TERM; /bin/sleep 0.8; echo leaked > \"$GINGER_HOME/leaked\"' &\nwait")
        do {
            _ = try await ScriptRunner.run(script: url, directory: dir,
                                           environment: [:], timeout: 0.1)
            XCTFail("Expected a timeout.")
        } catch { XCTAssertTrue(error is GingerError) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("leaked").path))
    }

    func testOutputLinksAreGenericUniqueAndSafeToOpen() {
        let output = ScriptOutput(title: "Report", detail:
            "See https://example.org/help\nhttps://example.org/help\nhttp://example.org/status\n"
                + "file:///tmp/private\nmailto:demo@example.org")
        XCTAssertEqual(output.links, [
            URL(string: "https://example.org/help")!, URL(string: "http://example.org/status")!
        ])
    }

    func testOutputLinkCountIsBounded() {
        let detail = (0..<12).map { "https://example.org/\($0)" }.joined(separator: "\n")
        XCTAssertEqual(ScriptOutput(title: "Links", detail: detail).links.count, 8)
    }

    func testLargeOutputDoesNotBlock() async throws {
        let dir = try temporaryDirectory()
        let url = try script(in: dir, body: "echo title; /usr/bin/yes x | /usr/bin/head -c 100000")
        let result = try await ScriptRunner.run(script: url, directory: dir, environment: [:])
        XCTAssertEqual(result.title, "title")
        XCTAssertLessThanOrEqual(result.detail.utf8.count, 8192)
    }
}
