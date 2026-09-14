import Foundation
import Darwin

/// Local MCP sessions that have actually exchanged a tools/resources request.
public struct AgentPresence: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var processId: Int32
    public var updatedAt: Date

    public static func active(in root: URL, now: Date = Date()) -> [AgentPresence] {
        let folder = root.appendingPathComponent("agents")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Self.self, from: data),
                  now.timeIntervalSince(entry.updatedAt) < 20, kill(entry.processId, 0) == 0 else { return nil }
            return entry
        }.sorted { $0.name < $1.name }
    }
}

public final class AgentPresenceSession: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private let id = UUID().uuidString
    private var timer: DispatchSourceTimer?
    private var url: URL { root.appendingPathComponent("agents/\(id).json") }
    public init(root: URL) { self.root = root }
    public func activate() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        write()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "xyz.screenpunk.agent-presence"))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.write() }
        self.timer = timer; timer.resume()
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel(); timer = nil
        try? FileManager.default.removeItem(at: url)
    }
    private func write() {
        let raw = ProcessInfo.processInfo.environment["SCREENPUNK_AGENT_NAME"] ?? "MCP Agent"
        let name = String(raw.filter { !$0.isNewline }.prefix(50))
        let entry = AgentPresence(id: id, name: name, processId: getpid(), updatedAt: Date())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: url, options: .atomic) }
    }
    deinit { stop() }
}
