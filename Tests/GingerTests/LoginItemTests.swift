import AppKit
import ServiceManagement
import XCTest
@testable import Ginger

final class LoginItemTests: XCTestCase {
    func testUnregisteredAndMissingLoginItemsCanBeEnabled() async {
        await MainActor.run {
            let delegate = AppDelegate()
            for status: SMAppService.Status in [.notRegistered, .notFound] {
                let menu = NSMenu()
                menu.autoenablesItems = false
                delegate.addStartAtLogin(to: menu, status: status)
                let item = menu.items.first
                XCTAssertEqual(item?.title, "Start at login")
                XCTAssertEqual(item?.state, .off)
                XCTAssertEqual(item?.isEnabled, true)
                XCTAssertNotNil(item?.action)
                XCTAssertTrue(item?.target === delegate)
            }
        }
    }

    func testEnabledLoginItemIsChecked() async {
        await MainActor.run {
            let delegate = AppDelegate()
            let menu = NSMenu()
            delegate.addStartAtLogin(to: menu, status: .enabled)
            XCTAssertEqual(menu.items.first?.state, .on)
            XCTAssertEqual(menu.items.first?.isEnabled, true)
        }
    }

    func testPendingApprovalHasSettingsAction() async {
        await MainActor.run {
            let delegate = AppDelegate()
            let menu = NSMenu()
            delegate.addStartAtLogin(to: menu, status: .requiresApproval)
            XCTAssertEqual(menu.items.first?.state, .mixed)
            XCTAssertEqual(menu.items.first?.isEnabled, true)
            XCTAssertEqual(menu.items.last?.title, "Approve in System Settings…")
            XCTAssertNotNil(menu.items.last?.action)
        }
    }
}
