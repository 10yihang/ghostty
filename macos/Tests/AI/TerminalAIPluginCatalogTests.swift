import Foundation
import Testing
@testable import Ghostty

struct TerminalAIPluginCatalogTests {
    @Test func builtinGuardianHasStableIdentityAndStaysOutOfPersonalScans() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.directory.appendingPathComponent("PiPlugins/codex-guardian", isDirectory: true)
        try fixture.json(["name": "@fixture/codex-guardian", "version": "1.0.0", "pi": ["extensions": ["index.ts"]]],
                         to: root.appendingPathComponent("package.json"))
        try fixture.file("index.ts", in: root, content: "throw new Error('Discovery must not execute the guardian');")
        let plugin = TerminalAIPluginCatalog.builtinGuardian(root: root)
        #expect(plugin.id == "builtin:codex-guardian")
        #expect(plugin.name == "Codex Guardian")
        #expect(plugin.version == "1.0.0")
        #expect(plugin.extensionPaths == [root.appendingPathComponent("index.ts").path])
        #expect(plugin.canEnable)
        #expect(plugin.compatibilityNote?.contains("Off by default") == true)
        #expect(try TerminalAIPluginCatalog.scan(agentDirectory: fixture.agent).isEmpty)
        let missing = TerminalAIPluginCatalog.builtinGuardian(root: fixture.directory.appendingPathComponent("missing-guardian"))
        #expect(missing.id == plugin.id)
        #expect(!missing.canEnable && missing.unavailableReason != nil)
    }

    @Test func appBundleContainsTheGuardianPackageAndEntry() throws {
        let resources = try #require(Bundle.main.resourceURL)
        let root = resources.appendingPathComponent("PiPlugins/codex-guardian", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("package.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.ts").path))
        let plugin = TerminalAIPluginCatalog.builtinGuardian(root: root)
        #expect(plugin.canEnable)
        #expect(plugin.extensionPaths == [root.resolvingSymlinksInPath().appendingPathComponent("index.ts").path])
        #expect(plugin.discoveryWarnings.isEmpty)
    }

    @Test func discoversInstalledPackagesIncludingScopesWithoutExecutingCode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let packages = [
            "pi-subagents", "pi-web-access", "@juicesharp/rpiv-ask-user-question", "pi-simplify",
            "pi-cc-extensions", "pi-memory", "@narumitw/pi-btw", "pi-session-import", "pi-model-manager",
        ]
        for name in packages {
            let root = try fixture.package(name, pi: ["extensions": ["index.js"]])
            try fixture.file("index.js", in: root, content: "throw new Error('discovery must not import this');")
        }
        let dependency = try fixture.package("ordinary-dependency", pi: nil)
        try fixture.file("index.js", in: dependency)
        try fixture.file("auth.json", in: fixture.agent, content: "not JSON and must never be read")
        try fixture.file("settings.json", in: fixture.agent, content: "not JSON and must never be read")
        try fixture.file("history/session.jsonl", in: fixture.agent, content: "private history")
        try fixture.file("memory/MEMORY.md", in: fixture.agent, content: "private memory")
        let result = try TerminalAIPluginCatalog.scan(agentDirectory: fixture.agent)
        #expect(Set(result.map(\.name)) == Set(packages))
        #expect(result.count == 9)
        #expect(result.allSatisfy { $0.version == "1.2.3" && $0.summary == "Fixture package" })
        #expect(result.allSatisfy { $0.extensionPaths == [$0.root.appendingPathComponent("index.js").path] })
        #expect(result.allSatisfy { $0.id == $0.root.path })
        #expect(result.first { $0.name == "pi-cc-extensions" }?.canEnable == false)
        #expect(result.first { $0.name == "pi-model-manager" }?.canEnable == false)
        #expect(result.first { $0.name == "pi-cc-extensions" }?.unavailableReason?.contains("Ghostty") == true)
        #expect(result.first { $0.name == "pi-model-manager" }?.unavailableReason?.contains("configuration") == true)
        #expect(result.first { $0.name == "@juicesharp/rpiv-ask-user-question" }?.compatibilityNote != nil)
        #expect(result.first { $0.name == "@narumitw/pi-btw" }?.compatibilityNote != nil)
        #expect(result.first { $0.name == "pi-web-access" }?.canEnable == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.agent.appendingPathComponent("executed").path))
    }

    @Test func manifestDirectoriesResolveEntryPointsInsteadOfImportingDependencies() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = try fixture.package("pi-directory", pi: ["extensions": ["./dist"], "skills": ["skills"], "prompts": ["prompts"]])
        try fixture.file("dist/index.js", in: root)
        try fixture.file("dist/helper.js", in: root)
        try fixture.file("dist/nested/index.js", in: root)
        try fixture.file("dist/node_modules/dependency/index.js", in: root)
        try fixture.file("skills/plain.md", in: root)
        try fixture.file("skills/review/SKILL.md", in: root)
        try fixture.file("skills/review/reference.md", in: root)
        try fixture.file("skills/review/nested/SKILL.md", in: root)
        try fixture.file("prompts/answer.md", in: root)
        try fixture.file("prompts/nested/plan.md", in: root)
        let plugin = try #require(TerminalAIPluginCatalog.scan(agentDirectory: fixture.agent).first)
        #expect(plugin.extensionPaths == [root.appendingPathComponent("dist/index.js").path])
        #expect(plugin.skillPaths == [root.appendingPathComponent("skills/plain.md").path,
                                     root.appendingPathComponent("skills/review/SKILL.md").path])
        #expect(plugin.promptPaths == [root.appendingPathComponent("prompts/answer.md").path,
                                      root.appendingPathComponent("prompts/nested/plan.md").path])
        #expect(plugin.discoveryWarnings.isEmpty)
    }

    @Test func extensionDirectoryDiscoveryStopsAtOneLevelAndHonorsNestedManifests() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = try fixture.package("pi-directory", pi: ["extensions": ["extensions"]])
        try fixture.file("extensions/direct.ts", in: root)
        try fixture.file("extensions/indexed/index.ts", in: root)
        try fixture.file("extensions/indexed/helper.ts", in: root)
        try fixture.file("extensions/unindexed/deep/index.ts", in: root)
        try fixture.file("extensions/manifest/entry.js", in: root)
        try fixture.json(["pi": ["extensions": ["entry.js"]]], to: root.appendingPathComponent("extensions/manifest/package.json"))
        let plugin = try #require(TerminalAIPluginCatalog.scan(agentDirectory: fixture.agent).first)
        #expect(plugin.extensionPaths == ["extensions/direct.ts", "extensions/indexed/index.ts", "extensions/manifest/entry.js"]
            .map { root.appendingPathComponent($0).path })
    }

    @Test func manifestGlobsExpandVisibleEntriesAndApplyOverrides() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = try fixture.package("pi-globs", pi: [
            "extensions": ["extensions/**/*.ts", "!**/helper.ts", "+extensions/nested/helper.ts", "-extensions/remove.ts"],
            "prompts": ["prompts/*.md"],
        ])
        for path in ["extensions/main.ts", "extensions/remove.ts", "extensions/helper.ts", "extensions/nested/helper.ts",
                     "extensions/.hidden.ts", "extensions/node_modules/dependency.ts", "prompts/answer.md", "prompts/nested/no.md"] {
            try fixture.file(path, in: root)
        }
        let plugin = try #require(TerminalAIPluginCatalog.scan(agentDirectory: fixture.agent).first)
        #expect(plugin.extensionPaths == [root.appendingPathComponent("extensions/main.ts").path,
                                         root.appendingPathComponent("extensions/nested/helper.ts").path])
        #expect(plugin.promptPaths == [root.appendingPathComponent("prompts/answer.md").path])
        #expect(plugin.discoveryWarnings.isEmpty)
    }

    @Test func missingAndUnsafeManifestEntriesStayVisibleWithoutFallbackLoading() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.directory.appendingPathComponent("outside.js")
        try "private outside content".write(to: outside, atomically: true, encoding: .utf8)
        let root = try fixture.package("pi-missing", pi: ["extensions": ["missing.js", "../outside.js", outside.path, "escape.js", "{one,two}/*.js"]])
        try fixture.file("extensions/index.js", in: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.js"), withDestinationURL: outside)
        let plugin = try #require(TerminalAIPluginCatalog.scan(agentDirectory: fixture.agent).first)
        #expect(plugin.extensionPaths.isEmpty)
        #expect(!plugin.canEnable)
        #expect(plugin.discoveryWarnings.contains { $0.contains("Missing extensions entry: missing.js") })
        #expect(plugin.discoveryWarnings.contains { $0.contains("Rejected path") })
        #expect(plugin.discoveryWarnings.contains { $0.contains("Unsupported resource glob") })
        #expect(try String(contentsOf: outside, encoding: .utf8) == "private outside content")
    }

    @Test func personalExtensionsUseFilesOrExplicitEntryAndDoNotReadPrivateDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("extensions/loose.ts", in: fixture.agent)
        try fixture.file("extensions/indexed/index.js", in: fixture.agent)
        try fixture.file("extensions/indexed/helper.js", in: fixture.agent)
        try fixture.file("extensions/unindexed/deep/index.ts", in: fixture.agent)
        try fixture.file("extensions/node_modules/ignored.ts", in: fixture.agent)
        let missing = fixture.agent.appendingPathComponent("extensions/missing")
        try fixture.json(["name": "personal-missing", "pi": ["extensions": ["gone.ts"]]], to: missing.appendingPathComponent("package.json"))
        let result = try TerminalAIPluginCatalog.scan(agentDirectory: fixture.agent)
        #expect(Set(result.map(\.name)) == ["loose", "indexed", "personal-missing"])
        #expect(result.first { $0.name == "loose" }?.extensionPaths == [fixture.agent.appendingPathComponent("extensions/loose.ts").path])
        #expect(result.first { $0.name == "indexed" }?.extensionPaths == [fixture.agent.appendingPathComponent("extensions/indexed/index.js").path])
        #expect(result.first { $0.name == "personal-missing" }?.canEnable == false)
        #expect(result.first { $0.name == "personal-missing" }?.discoveryWarnings.contains { $0.contains("gone.ts") } == true)
    }

    @Test func emptyManifestDisablesConventionsAndMissingAgentIsEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = try fixture.package("pi-empty", pi: ["extensions": []])
        try fixture.file("extensions/index.js", in: root)
        try fixture.file("skills/SKILL.md", in: root)
        let plugin = try #require(TerminalAIPluginCatalog.scan(agentDirectory: fixture.agent).first)
        #expect(plugin.extensionPaths.isEmpty && plugin.skillPaths.isEmpty && plugin.promptPaths.isEmpty)
        #expect(!plugin.canEnable)
        #expect(try TerminalAIPluginCatalog.scan(agentDirectory: fixture.directory.appendingPathComponent("absent")).isEmpty)
    }

    @Test func packageAndDiscoveryRootSymlinksCannotRedirectScanningIntoPrivateData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let privateDirectory = fixture.agent.appendingPathComponent("memory", isDirectory: true)
        try fixture.json(["name": "pi-private", "pi": ["extensions": ["index.js"]]],
                         to: privateDirectory.appendingPathComponent("package.json"))
        try fixture.file("index.js", in: privateDirectory)
        let npm = fixture.agent.appendingPathComponent("npm/node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: npm, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: npm.appendingPathComponent("pi-private"), withDestinationURL: privateDirectory)
        try FileManager.default.createSymbolicLink(at: fixture.agent.appendingPathComponent("extensions"), withDestinationURL: privateDirectory)
        #expect(try TerminalAIPluginCatalog.scan(agentDirectory: fixture.agent).isEmpty)
    }

    private struct Fixture {
        let directory: URL
        let agent: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-plugin-catalog-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            agent = directory.appendingPathComponent("agent", isDirectory: true)
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func package(_ name: String, pi: [String: Any]?) throws -> URL {
            let root = agent.appendingPathComponent("npm/node_modules/\(name)", isDirectory: true)
            var metadata: [String: Any] = ["name": name, "version": "1.2.3", "description": "Fixture package"]
            if let pi { metadata["pi"] = pi }
            try json(metadata, to: root.appendingPathComponent("package.json"))
            return root
        }

        func json(_ object: [String: Any], to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        }

        func file(_ path: String, in root: URL, content: String = "fixture") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
