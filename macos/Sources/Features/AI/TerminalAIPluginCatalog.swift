import Foundation

/// Metadata and entry paths only. Discovery never imports extension code.
struct TerminalAIPlugin: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let summary: String
    let root: URL
    let extensionPaths: [String]
    let skillPaths: [String]
    let promptPaths: [String]
    let compatibilityNote: String?
    let unavailableReason: String?
    let discoveryWarnings: [String]

    var canEnable: Bool {
        unavailableReason == nil && !(extensionPaths + skillPaths + promptPaths).isEmpty
    }

    init(
        id: String, name: String, version: String = "", summary: String = "", root: URL,
        extensionPaths: [String] = [], skillPaths: [String] = [], promptPaths: [String] = [],
        compatibilityNote: String? = nil, unavailableReason: String? = nil, discoveryWarnings: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.root = root
        self.extensionPaths = extensionPaths
        self.skillPaths = skillPaths
        self.promptPaths = promptPaths
        self.compatibilityNote = compatibilityNote
        self.unavailableReason = unavailableReason
        self.discoveryWarnings = discoveryWarnings
    }
}

enum TerminalAIPluginCatalog {
    static func scan(agentDirectory: URL) throws -> [TerminalAIPlugin] {
        try Scanner().scan(agentDirectory: agentDirectory)
    }

    private final class Scanner {
        private let manager = FileManager.default
        private let maximumEntries = 16_384
        private let maximumManifestBytes = 256 * 1_024
        private var remainingEntries = 16_384

        func scan(agentDirectory: URL) throws -> [TerminalAIPlugin] {
            let agent = agentDirectory.standardizedFileURL.resolvingSymlinksInPath()
            guard isDirectory(agent) else { return [] }
            var plugins: [TerminalAIPlugin] = []
            let npm = agent.appendingPathComponent("npm/node_modules", isDirectory: true)
            let npmEntries = npm.standardizedFileURL.path == npm.resolvingSymlinksInPath().path ? try children(npm) : []
            for directory in npmEntries where isDirectory(directory) && contained(directory, in: npm) {
                let packages = directory.lastPathComponent.hasPrefix("@") ? try children(directory) : [directory]
                for package in packages where isDirectory(package) {
                    guard contained(package, in: npm) else { continue }
                    var warnings: [String] = []
                    guard let metadata = manifest(package, warnings: &warnings) else { continue }
                    let pi = metadata["pi"] as? [String: Any]
                    let keywords = metadata["keywords"] as? [String] ?? []
                    guard pi != nil || keywords.contains("pi-package") else { continue }
                    plugins.append(plugin(root: package, metadata: metadata, pi: pi, warnings: warnings))
                }
            }
            let extensions = agent.appendingPathComponent("extensions", isDirectory: true)
            let personalEntries = extensions.standardizedFileURL.path == extensions.resolvingSymlinksInPath().path ? try children(extensions) : []
            for entry in personalEntries {
                guard contained(entry, in: extensions) else { continue }
                if isDirectory(entry) {
                    var warnings: [String] = []
                    let metadata = manifest(entry, warnings: &warnings) ?? [:]
                    let paths = extensionEntries(entry, boundary: entry, warnings: &warnings)
                    // A personal directory with a manifest but a missing entry remains visible.
                    guard !paths.isEmpty || metadata["pi"] != nil else { continue }
                    plugins.append(plugin(root: entry, metadata: metadata, pi: metadata["pi"] as? [String: Any],
                                          warnings: warnings, personalExtensions: paths))
                } else if isFile(entry), ["ts", "js"].contains(entry.pathExtension) {
                    let root = entry.standardizedFileURL.resolvingSymlinksInPath()
                    plugins.append(TerminalAIPlugin(id: root.path, name: entry.deletingPathExtension().lastPathComponent,
                                                    summary: "Personal Pi extension", root: root,
                                                    extensionPaths: [root.path]))
                }
            }
            var seen = Set<String>()
            return plugins.filter { seen.insert($0.id).inserted }.sorted {
                if $0.name == $1.name { return $0.id < $1.id }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }

        private func plugin(
            root: URL, metadata: [String: Any], pi: [String: Any]?, warnings: [String],
            personalExtensions: [String]? = nil
        ) -> TerminalAIPlugin {
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            var warnings = warnings
            let name = metadata["name"] as? String ?? root.lastPathComponent
            let extensions = personalExtensions ?? resources("extensions", pi: pi, root: root, warnings: &warnings)
            let skills = resources("skills", pi: pi, root: root, warnings: &warnings)
            let prompts = resources("prompts", pi: pi, root: root, warnings: &warnings)
            if extensions.isEmpty && skills.isEmpty && prompts.isEmpty {
                warnings.append("No supported extension, skill, or prompt entry was found.")
            }
            let unavailable: String?
            switch name {
            case "pi-cc-extensions":
                unavailable = "Changes Pi's terminal UI; Ghostty uses its own AI panel."
            case "pi-model-manager":
                unavailable = "Needs Pi's interactive terminal UI to manage model and provider configuration."
            default: unavailable = nil
            }
            let note: String?
            switch name {
            case "@juicesharp/rpiv-ask-user-question":
                note = "Questionnaires need Pi's terminal UI; Ghostty interaction support has not been verified."
            case "@narumitw/pi-btw":
                note = "The side-question interface needs Pi's terminal UI; Ghostty interaction support has not been verified."
            case "pi-session-import":
                note = "Session-selection prompts need a native picker that is not supported yet; search and import tools can still load."
            default: note = nil
            }
            return TerminalAIPlugin(id: root.path, name: name, version: metadata["version"] as? String ?? "",
                                    summary: metadata["description"] as? String ?? "Personal Pi extension", root: root,
                                    extensionPaths: extensions, skillPaths: skills, promptPaths: prompts,
                                    compatibilityNote: note, unavailableReason: unavailable,
                                    discoveryWarnings: Array(Set(warnings)).sorted())
        }

        private func resources(_ type: String, pi: [String: Any]?, root: URL, warnings: inout [String]) -> [String] {
            let entries: [String]
            if let pi {
                guard let value = pi[type] else { return [] }
                guard let declared = value as? [String] else {
                    warnings.append("pi.\(type) must be an array of paths.")
                    return []
                }
                entries = declared
            } else {
                guard isDirectory(root.appendingPathComponent(type)) else { return [] }
                entries = [type]
            }
            var paths: [String] = []
            for entry in entries where !isOverride(entry) {
                guard validRelativePath(entry) else {
                    warnings.append("Rejected path outside the package: \(entry)")
                    continue
                }
                let candidates: [URL]
                if entry.contains("*") || entry.contains("?") {
                    candidates = glob(entry, root: root, warnings: &warnings)
                } else {
                    candidates = [root.appendingPathComponent(entry).standardizedFileURL]
                }
                var discovered: [String] = []
                for candidate in candidates {
                    guard contained(candidate, in: root) else {
                        warnings.append("Rejected path outside the package: \(entry)")
                        continue
                    }
                    if isFile(candidate) {
                        discovered.append(candidate.resolvingSymlinksInPath().path)
                    } else if isDirectory(candidate) {
                        discovered += collect(candidate, type: type, boundary: root, warnings: &warnings)
                    }
                }
                if discovered.isEmpty { warnings.append("Missing \(type) entry: \(entry)") }
                paths += discovered
            }
            return Array(Set(paths)).sorted().filter { path in
                let relative = String(path.dropFirst(root.path.count + 1))
                var enabled = true
                for entry in entries where entry.hasPrefix("!") {
                    let pattern = String(entry.dropFirst())
                    if patternMatches(path, relative: relative, pattern: pattern, root: root) {
                        enabled = false
                    }
                }
                for entry in entries where entry.hasPrefix("+") {
                    if exact(path, pattern: String(entry.dropFirst()), root: root) { enabled = true }
                }
                for entry in entries where entry.hasPrefix("-") {
                    if exact(path, pattern: String(entry.dropFirst()), root: root) { enabled = false }
                }
                return enabled
            }
        }

        /// Pi 1.1.0 uses an index/manifest first, then direct files and one level of indexed subdirectories.
        private func collect(_ directory: URL, type: String, boundary: URL, warnings: inout [String]) -> [String] {
            if type == "extensions" {
                let explicit = extensionEntries(directory, boundary: boundary, warnings: &warnings)
                if !explicit.isEmpty { return explicit }
                var paths: [String] = []
                for child in safeChildren(directory, warnings: &warnings) where contained(child, in: boundary) {
                    if isFile(child), ["ts", "js"].contains(child.pathExtension) {
                        paths.append(child.resolvingSymlinksInPath().path)
                    } else if isDirectory(child) {
                        paths += extensionEntries(child, boundary: boundary, warnings: &warnings)
                    }
                }
                return paths
            }
            return markdown(directory, skills: type == "skills", boundary: boundary, topLevel: true, warnings: &warnings)
        }

        private func extensionEntries(_ directory: URL, boundary: URL, warnings: inout [String]) -> [String] {
            if let metadata = manifest(directory, warnings: &warnings),
               let pi = metadata["pi"] as? [String: Any], let entries = pi["extensions"] as? [String], !entries.isEmpty {
                var paths: [String] = []
                for entry in entries {
                    guard validRelativePath(entry), !isOverride(entry), !entry.contains("*"), !entry.contains("?") else {
                        warnings.append("Unsupported personal extension entry: \(entry)")
                        continue
                    }
                    let target = directory.appendingPathComponent(entry).standardizedFileURL
                    guard contained(target, in: boundary) else {
                        warnings.append("Rejected path outside the package: \(entry)")
                        continue
                    }
                    if isFile(target) { paths.append(target.resolvingSymlinksInPath().path) } else if isDirectory(target) { warnings.append("Extension entry must resolve to a file: \(entry)") } else { warnings.append("Missing extensions entry: \(entry)") }
                }
                if !paths.isEmpty { return paths }
            }
            for name in ["index.ts", "index.js"] {
                let index = directory.appendingPathComponent(name)
                if contained(index, in: boundary), isFile(index) { return [index.resolvingSymlinksInPath().path] }
            }
            return []
        }

        private func markdown(
            _ directory: URL, skills: Bool, boundary: URL, topLevel: Bool, warnings: inout [String], depth: Int = 0
        ) -> [String] {
            guard depth < 32 else { warnings.append("Resource directory nesting exceeds the discovery limit."); return [] }
            let skill = directory.appendingPathComponent("SKILL.md")
            if skills, contained(skill, in: boundary), isFile(skill) { return [skill.resolvingSymlinksInPath().path] }
            var paths: [String] = []
            for child in safeChildren(directory, warnings: &warnings) where contained(child, in: boundary) {
                if isDirectory(child) {
                    paths += markdown(child, skills: skills, boundary: boundary, topLevel: false, warnings: &warnings, depth: depth + 1)
                } else if isFile(child), child.pathExtension == "md", !skills || topLevel {
                    paths.append(child.resolvingSymlinksInPath().path)
                }
            }
            return paths
        }

        private func glob(_ pattern: String, root: URL, warnings: inout [String]) -> [URL] {
            // Keep uncommon Node glob syntax visible without guessing broader entry paths.
            guard !pattern.contains(where: { "[]{}()\\".contains($0) }) else {
                warnings.append("Unsupported resource glob: \(pattern)")
                return []
            }
            var matches: [URL] = []
            func walk(_ directory: URL, depth: Int) {
                guard depth < 32 else { return }
                for child in safeChildren(directory, warnings: &warnings) where contained(child, in: root) {
                    let relative = String(child.standardizedFileURL.path.dropFirst(root.path.count + 1))
                    if self.matches(relative, pattern: pattern) { matches.append(child) }
                    if isDirectory(child) { walk(child, depth: depth + 1) }
                }
            }
            walk(root, depth: 0)
            return matches.sorted { $0.path < $1.path }
        }

        private func matches(_ path: String, pattern: String) -> Bool {
            var pattern = pattern
            while pattern.hasPrefix("./") { pattern.removeFirst(2) }
            var expression = "^"
            let characters = Array(pattern)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                    index += 1
                    if index + 1 < characters.count, characters[index + 1] == "/" {
                        expression += "(?:.*/)?"
                        index += 1
                    } else { expression += ".*" }
                } else if character == "*" { expression += "[^/]*" } else if character == "?" { expression += "[^/]" } else { expression += NSRegularExpression.escapedPattern(for: String(character)) }
                index += 1
            }
            return path.range(of: expression + "$", options: .regularExpression) != nil
        }

        private func exact(_ path: String, pattern: String, root: URL) -> Bool {
            guard validRelativePath(pattern) else { return false }
            let target = root.appendingPathComponent(pattern).standardizedFileURL.resolvingSymlinksInPath().path
            return target == path || (URL(fileURLWithPath: path).lastPathComponent == "SKILL.md" &&
                                      URL(fileURLWithPath: path).deletingLastPathComponent().path == target)
        }

        private func patternMatches(_ path: String, relative: String, pattern: String, root: URL) -> Bool {
            let file = URL(fileURLWithPath: path)
            if matches(relative, pattern: pattern) || matches(file.lastPathComponent, pattern: pattern) || matches(path, pattern: pattern) {
                return true
            }
            guard file.lastPathComponent == "SKILL.md" else { return false }
            let parent = file.deletingLastPathComponent()
            return matches(String(parent.path.dropFirst(root.path.count + 1)), pattern: pattern) ||
                matches(parent.lastPathComponent, pattern: pattern) || matches(parent.path, pattern: pattern)
        }

        private func manifest(_ root: URL, warnings: inout [String]) -> [String: Any]? {
            let url = root.appendingPathComponent("package.json")
            guard contained(url, in: root), isFile(url) else { return nil }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var data = try handle.read(upToCount: maximumManifestBytes + 1) ?? Data()
                guard data.count <= maximumManifestBytes else {
                    warnings.append("package.json exceeds the 256 KiB discovery limit.")
                    return nil
                }
                if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
                return try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } catch {
                warnings.append("Could not read package.json: \(error.localizedDescription)")
                return nil
            }
        }

        private func safeChildren(_ directory: URL, warnings: inout [String]) -> [URL] {
            do { return try children(directory) } catch { warnings.append(error.localizedDescription); return [] }
        }

        private func children(_ directory: URL) throws -> [URL] {
            guard isDirectory(directory) else { return [] }
            var failure: Error?
            guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                                                      errorHandler: { _, error in failure = error; return false }) else { return [] }
            var entries: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                guard remainingEntries > 0 else {
                    throw NSError(domain: "TerminalAIPluginCatalog", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Pi plugin discovery exceeds the \(maximumEntries) entry limit."])
                }
                remainingEntries -= 1
                if url.lastPathComponent != "node_modules" { entries.append(url) }
            }
            if let failure { throw failure }
            return entries.sorted { $0.path < $1.path }
        }

        private func validRelativePath(_ path: String) -> Bool {
            !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/") && !path.hasPrefix("~") &&
                !path.contains("\0") && !path.split(separator: "/").contains("..")
        }

        private func isOverride(_ path: String) -> Bool {
            path.hasPrefix("!") || path.hasPrefix("+") || path.hasPrefix("-")
        }

        private func contained(_ path: URL, in root: URL) -> Bool {
            let path = path.standardizedFileURL.resolvingSymlinksInPath().path
            let root = root.standardizedFileURL.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }

        private func isDirectory(_ url: URL) -> Bool {
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        private func isFile(_ url: URL) -> Bool {
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}
