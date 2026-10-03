import Darwin
import Foundation

public struct ScriptOutput {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    public var links: [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(detail.startIndex..<detail.endIndex, in: detail)
        var seen = Set<URL>()
        return Array(detector.matches(in: detail, range: range).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host != nil,
                  seen.insert(url).inserted else { return nil }
            return url
        }.prefix(8))
    }
}

public enum ScriptRunner {
    public static func run(script: URL, directory: URL,
                           environment: [String: String], timeout: TimeInterval = 20) async throws -> ScriptOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try execute(script: script, directory: directory,
                        environment: environment, timeout: timeout))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func execute(script: URL, directory: URL,
                                environment: [String: String], timeout: TimeInterval) throws -> ScriptOutput {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("ginger-\(UUID().uuidString)")
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: temporary) }
        let stdout = temporary.appendingPathComponent("stdout")
        let stderr = temporary.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fileManager.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }

        let process = Process()
        process.executableURL = script
        process.currentDirectoryURL = directory
        var variables = ProcessInfo.processInfo.environment
        let home = fileManager.homeDirectoryForCurrentUser.path
        variables["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
            + (variables["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        variables.merge(environment) { _, new in new }
        variables["GINGER_HOME"] = directory.path
        process.environment = variables
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // macOS Process creates a process group. Check it before signaling descendants.
        let pid = process.processIdentifier
        let group = getpgid(pid) == pid ? pid : nil
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if let group { kill(-group, SIGTERM) } else { process.terminate() }
            let timedOut = finished.wait(timeout: .now() + 1) == .timedOut
            // A child can keep running after the script process exits.
            if let group { kill(-group, SIGKILL) } else if timedOut { kill(pid, SIGKILL) }
            if timedOut { _ = finished.wait(timeout: .now() + 2) }
            throw GingerError("Script exceeded the \(Int(timeout))-second timeout.")
        }
        let errorText = try readText(stderr)
        guard process.terminationStatus == 0 else {
            throw GingerError(errorText.isEmpty ? "Script exited with status \(process.terminationStatus)." : errorText)
        }
        let text = try readText(stdout)
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first else {
            throw GingerError("Script returned no text.")
        }
        return ScriptOutput(title: String(firstLine.prefix(80)), detail: text)
    }

    private static func readText(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8192) ?? Data()
        // Keep script output readable when it contains invalid UTF-8 bytes.
        // swiftlint:disable:next optional_data_string_conversion
        let string = String(decoding: data, as: UTF8.self)
        return String(string.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
