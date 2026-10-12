import AppKit
import GingerCore
import XCTest
@testable import Ginger

final class WidgetMenuTests: XCTestCase {
    func testOutputUsesSeparateCompactRowsAndDoesNotRepeatLinkURLs() async {
        await MainActor.run {
            let delegate = AppDelegate()
            let menu = NSMenu()
            menu.autoenablesItems = false
            let output = ScriptOutput(title: "5h 🌤️ · 10°C", detail:
                "5h 🌤️ · 10°C\n\nCloudy → Partly cloudy\nhttps://open-meteo.com/")
            delegate.addOutputDetails(output, to: menu)
            delegate.addOutputLinks(output, to: menu)
            XCTAssertEqual(menu.items.map(\.title), [
                "5h 🌤️ · 10°C", "Cloudy → Partly cloudy", "Open open-meteo.com"
            ])
            XCTAssertTrue(menu.items.prefix(2).allSatisfy { !$0.isEnabled && $0.action == nil })
        }
    }

    func testLongOutputRowsAreShortenedButKeepFullTooltips() async {
        await MainActor.run {
            let delegate = AppDelegate()
            let menu = NSMenu()
            let longLine = String(repeating: "x", count: 200)
            delegate.addOutputDetails(ScriptOutput(title: "Report", detail: longLine), to: menu)
            XCTAssertEqual(menu.items.first?.title, String(repeating: "x", count: 63) + "…")
            XCTAssertEqual(menu.items.first?.toolTip, longLine)
        }
    }

    func testOutputRowCountIsBoundedAndExtraTextRemainsAvailable() async {
        await MainActor.run {
            let delegate = AppDelegate()
            let menu = NSMenu()
            let detail = (0..<20).map { "Line \($0)" }.joined(separator: "\n")
            delegate.addOutputDetails(ScriptOutput(title: "Report", detail: detail), to: menu)
            XCTAssertEqual(menu.items.count, 9)
            XCTAssertEqual(menu.items.last?.title, "More output…")
            XCTAssertEqual(menu.items.last?.toolTip, detail)
        }
    }

    func testAnyWidgetCanProvideAnOutputLink() async {
        await MainActor.run {
            let delegate = AppDelegate()
            let menu = NSMenu()
            let output = ScriptOutput(title: "Custom report", detail: "Data source: https://example.org/report")
            delegate.addOutputLinks(output, to: menu)
            XCTAssertEqual(menu.items.first?.title, "Open example.org")
            XCTAssertEqual(menu.items.first?.representedObject as? URL, URL(string: "https://example.org/report"))
            XCTAssertTrue(menu.items.first?.target === delegate)
        }
    }
}
