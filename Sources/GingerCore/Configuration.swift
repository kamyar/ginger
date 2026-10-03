import Foundation

public struct WidgetConfiguration: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var displaySeconds: Double
    public var refreshSeconds: Double
    public var environment: [String: String]

    public init(id: String, name: String? = nil, enabled: Bool = true,
                displaySeconds: Double = 10, refreshSeconds: Double = 300,
                environment: [String: String] = [:]) {
        self.id = id
        self.name = name ?? id
        self.enabled = enabled
        self.displaySeconds = displaySeconds
        self.refreshSeconds = refreshSeconds
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, displaySeconds, refreshSeconds, environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        displaySeconds = try container.decodeIfPresent(Double.self, forKey: .displaySeconds) ?? 10
        refreshSeconds = try container.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? 300
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }
}

public struct Configuration: Codable, Equatable {
    public var widgets: [WidgetConfiguration]
    public init(widgets: [WidgetConfiguration] = []) { self.widgets = widgets }

    public func validate() throws {
        var ids = Set<String>()
        for widget in widgets {
            guard !widget.id.isEmpty, widget.id != ".", widget.id != "..",
                  !widget.id.contains("/"), !widget.id.contains("\0"),
                  ids.insert(widget.id).inserted else {
                throw GingerError("Each widget needs a unique script filename without a directory.")
            }
            guard !widget.name.isEmpty,
                  widget.displaySeconds.isFinite, widget.displaySeconds >= 1,
                  widget.refreshSeconds.isFinite, widget.refreshSeconds >= 1 else {
                throw GingerError("Widget names must not be empty. Intervals must be at least 1 second.")
            }
            guard widget.environment.allSatisfy({
                !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0")
            }) else { throw GingerError("A widget has an invalid environment variable.") }
        }
    }
}

public struct GingerError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ConfigurationStore {
    public let directory: URL
    public var scriptsDirectory: URL { directory.appendingPathComponent("widgets", isDirectory: true) }
    public var file: URL { directory.appendingPathComponent("config.json") }

    public init(directory: URL) { self.directory = directory }

    public static var standard: ConfigurationStore {
        let path = ProcessInfo.processInfo.environment["GINGER_HOME"]
        return ConfigurationStore(directory: path.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ginger"))
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func scriptExists(_ id: String) -> Bool {
        let path = scriptsDirectory.appendingPathComponent(id).path
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    public func load() throws -> Configuration {
        try prepare()
        var configuration: Configuration
        if FileManager.default.fileExists(atPath: file.path) {
            configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
        } else {
            configuration = Configuration()
        }
        try configuration.validate()
        let names = try FileManager.default.contentsOfDirectory(atPath: scriptsDirectory.path)
            .filter { !$0.hasPrefix(".") && scriptExists($0) }.sorted()
        let known = Set(configuration.widgets.map(\.id))
        for name in names where !known.contains(name) {
            configuration.widgets.append(WidgetConfiguration(id: name))
        }
        // Keep settings for missing scripts. They do not run until the script returns.
        try save(configuration)
        return configuration
    }

    public func save(_ configuration: Configuration) throws {
        try configuration.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(configuration).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
