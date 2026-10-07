import Testing
import Foundation
import Sparkle
@testable import Ghostty

@MainActor
struct UpdateConfigurationTests {
    private static let feed = "https://github.com/10yihang/ghostty/releases/latest/download/appcast.xml"
    private static let testKey = Data(repeating: 33, count: 32).base64EncodedString()
    private static let upstreamKey = "wsNcGf5hirwtdXMVnYoxRIX/SqZQLMOsYlD3q3imeok="

    @Test func sourceInfoSurvivesTheBuildsCPreprocessor() async throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Ghostty-Info.plist")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-preprocessed-info-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["clang", "-E", "-P", "-x", "c", source.path, "-o", output.path]
            try process.run()
            process.waitUntilExit()
            return (status: process.terminationStatus, data: try Data(contentsOf: output))
        }.value
        #expect(result.status == 0)
        let original = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: source), format: nil) as? [String: Any])
        let processed = try #require(PropertyListSerialization.propertyList(
            from: result.data, format: nil) as? [String: Any])
        #expect(processed["SUFeedURL"] as? String == Self.feed)
        #expect(processed["SUPublicEDKey"] as? String == original["SUPublicEDKey"] as? String)
    }

    @Test func delegateUsesTheForkFeedFromItsActualHostBundle() throws {
        let fixture = try HostFixture(info: ["SUFeedURL": Self.feed, "SUPublicEDKey": Self.testKey])
        defer { fixture.remove() }
        let driver = UpdateDriver(viewModel: .init(), hostBundle: fixture.bundle)
        let updater = SPUUpdater(
            hostBundle: fixture.bundle, applicationBundle: fixture.bundle,
            userDriver: driver, delegate: driver)
        // A previous official build may have persisted its feed preference.
        let defaults = try #require(UserDefaults(suiteName: fixture.identifier))
        defaults.set("https://release.files.ghostty.org/appcast.xml", forKey: "SUFeedURL")
        defer { defaults.removePersistentDomain(forName: fixture.identifier) }
        #expect(driver.feedURLString(for: updater) == Self.feed)
        #expect(updater.feedURL?.absoluteString == Self.feed)
        try driver.updater(updater, mayPerform: .updates)
        #expect(!updater.canCheckForUpdates, "The fixture has not started Sparkle or contacted a feed")
    }

    @Test(arguments: [
        "http://github.com/10yihang/ghostty/releases/latest/download/appcast.xml",
        "https://release.files.ghostty.org/appcast.xml",
        "https://tip.files.ghostty.org/appcast.xml",
        "https://github.com/other-owner/ghostty/releases/latest/download/appcast.xml",
        "https://user:secret@github.com/10yihang/ghostty/releases/latest/download/appcast.xml",
        "https://github.com/10yihang/ghostty/releases/latest/download/appcast.xml?source=official",
        "https://github.com/10yihang/ghostty/releases/latest/download/appcast.xml#fragment",
        "not a URL"
    ])
    func invalidFeedsCannotUseAnOfficialFallback(_ feed: String) throws {
        let fixture = try HostFixture(info: ["SUFeedURL": feed, "SUPublicEDKey": Self.testKey])
        defer { fixture.remove() }
        let driver = UpdateDriver(viewModel: .init(), hostBundle: fixture.bundle)
        let updater = SPUUpdater(
            hostBundle: fixture.bundle, applicationBundle: fixture.bundle,
            userDriver: driver, delegate: driver)
        #expect(driver.feedURLString(for: updater) == "")
        #expect(updater.feedURL == nil)
        #expect(throws: (any Error).self) {
            try driver.updater(updater, mayPerform: .updates)
        }
    }

    @Test(arguments: ["", "invalid-key", Data(repeating: 33, count: 31).base64EncodedString(), upstreamKey])
    func missingInvalidOrOfficialKeysNeverStartOrCheck(_ key: String) throws {
        let fixture = try HostFixture(info: ["SUFeedURL": Self.feed, "SUPublicEDKey": key])
        defer { fixture.remove() }
        let controller = UpdateController(hostBundle: fixture.bundle)
        controller.startUpdater()
        #expect(!controller.updater.canCheckForUpdates)
        #expect(controller.updater.feedURL == nil)
        #expect(controller.viewModel.text.contains("Fork updates unavailable"))
        controller.checkForUpdates()
        #expect(!controller.updater.canCheckForUpdates)
        guard case .error(let state) = controller.viewModel.state else {
            Issue.record("Invalid configuration must remain a visible native error")
            return
        }
        #expect(state.error.localizedDescription.contains("signing key"))
        state.dismiss()
        #expect(controller.viewModel.state == .idle)
    }

    @Test func missingFeedFailsBothNativeControllerAndDelegateBeforeAnyCheck() throws {
        let fixture = try HostFixture(info: ["SUPublicEDKey": Self.testKey])
        defer { fixture.remove() }
        let controller = UpdateController(hostBundle: fixture.bundle)
        controller.startUpdater()
        #expect(controller.viewModel.text.contains("SUFeedURL"))
        #expect(!controller.updater.canCheckForUpdates)
        controller.checkForUpdates()
        #expect(controller.viewModel.text.contains("SUFeedURL"))
        let driver = UpdateDriver(viewModel: .init(), hostBundle: fixture.bundle)
        #expect(driver.feedURLString(for: controller.updater) == "")
        #expect(controller.updater.feedURL == nil)
        #expect(throws: (any Error).self) {
            try driver.updater(controller.updater, mayPerform: .updatesInBackground)
        }
    }

    private struct HostFixture {
        let url: URL
        let bundle: Bundle
        let identifier: String

        init(info: [String: Any]) throws {
            identifier = "com.ghostty.update-policy.test.\(UUID().uuidString)"
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ghostty-updater-\(UUID().uuidString).app")
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var metadata = info
            metadata["CFBundleIdentifier"] = identifier
            metadata["CFBundleName"] = "Ghostty Update Fixture"
            metadata["CFBundleExecutable"] = "Ghostty"
            metadata["CFBundleVersion"] = "1"
            metadata["CFBundleShortVersionString"] = "1.0"
            metadata["SUEnableAutomaticChecks"] = false
            metadata["SUAutomaticallyUpdate"] = false
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            bundle = try #require(Bundle(url: url))
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }
}
