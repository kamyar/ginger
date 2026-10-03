import AppKit
import GingerCore
import XCTest
@testable import Ginger

final class WidgetMenuTests: XCTestCase {
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
