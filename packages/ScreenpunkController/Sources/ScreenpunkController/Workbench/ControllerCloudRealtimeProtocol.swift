import Foundation

/// A controller-only session. Neither installation credentials nor native-device claims belong here.
public struct ControllerCloudRealtimeSession: Decodable, Sendable {
    public struct Firebase: Decodable, Sendable {
        public let projectId: String
        public let databaseURL: URL
        public let apiKey: String
        public let appId: String
        public let messagingSenderId: String
        public init(projectId: String, databaseURL: URL, apiKey: String, appId: String, messagingSenderId: String) {
            self.projectId = projectId; self.databaseURL = databaseURL; self.apiKey = apiKey
            self.appId = appId; self.messagingSenderId = messagingSenderId
        }
    }
    public let schemaVersion: Int
    public let transport: String
    public let firebase: Firebase
    public let customToken: String
    public let firebaseUID: String
    public let subscriberId: String
    public let generationId: String
    public let wakePath: String
    public let cursor: String
    public let authorityExpiresAtMs: Int64
    public init(schemaVersion: Int = 1, transport: String = "firebase-rtdb", firebase: Firebase,
                customToken: String, firebaseUID: String, subscriberId: String, generationId: String,
                wakePath: String, cursor: String, authorityExpiresAtMs: Int64) {
        self.schemaVersion = schemaVersion; self.transport = transport; self.firebase = firebase
        self.customToken = customToken; self.firebaseUID = firebaseUID; self.subscriberId = subscriberId
        self.generationId = generationId; self.wakePath = wakePath; self.cursor = cursor
        self.authorityExpiresAtMs = authorityExpiresAtMs
    }
    func validate(now: Date) throws {
        let uuid = "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"
        guard schemaVersion == 1, transport == "firebase-rtdb",
              subscriberId.range(of: uuid, options: .regularExpression) != nil,
              generationId.range(of: uuid, options: .regularExpression) != nil,
              firebaseUID == "spctl:\(subscriberId):\(generationId)",
              wakePath == "v1/controllers/\(subscriberId)/wake",
              ControllerCloudRealtimeCursor.valid(cursor),
              authorityExpiresAtMs > Int64(now.timeIntervalSince1970 * 1000),
              Double(authorityExpiresAtMs) <= now.timeIntervalSince1970 * 1000 + 3_660_000,
              !customToken.isEmpty, customToken.utf8.count <= 16_384,
              firebase.projectId.range(of: "^[a-z0-9][a-z0-9-]{3,62}$", options: .regularExpression) != nil,
              !firebase.apiKey.isEmpty, firebase.apiKey.utf8.count <= 256,
              !firebase.appId.isEmpty, firebase.appId.utf8.count <= 256,
              !firebase.messagingSenderId.isEmpty, firebase.messagingSenderId.utf8.count <= 128,
              ControllerCloudRealtimeURLPolicy.databaseOrigin(firebase.databaseURL) else {
            throw ControllerCloudRealtimeFailure.invalidSession
        }
    }
}

public enum ControllerCloudRealtimeFailure: Error, Equatable, Sendable {
    case invalidSession, invalidResponse, frameLimit, invalidScope, permissionDenied, authenticationRequired
}

enum ControllerCloudRealtimeCursor {
    static func valid(_ value: String) -> Bool {
        value.range(of: "^[1-9][0-9]{0,18}$", options: .regularExpression) != nil &&
            (value.count < 19 || value <= "9223372036854775807")
    }
    static func greater(_ a: String, than b: String) -> Bool { a.count == b.count ? a > b : a.count > b.count }
}

struct ControllerCloudRealtimeSSEEvent: Sendable { let name: String; let data: Data }
/// Incremental byte framing handles split UTF-8/CRLF without retaining an unbounded line or frame.
struct ControllerCloudRealtimeSSEDecoder {
    private var line = Data(), payload = Data(), name = ""
    private var frameBytes = 0
    mutating func append(_ bytes: Data) throws -> [ControllerCloudRealtimeSSEEvent] {
        guard bytes.count <= 65_536 else { throw ControllerCloudRealtimeFailure.frameLimit }
        var events: [ControllerCloudRealtimeSSEEvent] = []
        for byte in bytes {
            if byte != 10 {
                line.append(byte)
                guard line.count <= 4_096 else { throw ControllerCloudRealtimeFailure.frameLimit }
                continue
            }
            if line.last == 13 { line.removeLast() }
            frameBytes += line.count + 1
            guard frameBytes <= 8_192 else { throw ControllerCloudRealtimeFailure.frameLimit }
            guard let text = String(data: line, encoding: .utf8) else { throw ControllerCloudRealtimeFailure.invalidResponse }
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
                if !name.isEmpty || !payload.isEmpty {
                    events.append(.init(name: name, data: payload))
                }
                name = ""; payload.removeAll(keepingCapacity: true); frameBytes = 0
            } else if !text.hasPrefix(":") {
                let pair = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                var value = pair.count == 2 ? String(pair[1]) : ""
                if value.hasPrefix(" ") { value.removeFirst() }
                if pair[0] == "event" { name = value }
                if pair[0] == "data" {
                    if !payload.isEmpty { payload.append(10) }
                    payload.append(contentsOf: value.utf8)
                }
            }
        }
        return events
    }
}

/// A wake is a cursor hint only; no project identity or command is accepted from this channel.
struct ControllerCloudRealtimeWakeDecoder {
    private var state: [String: Any] = [:]
    private(set) var cursor: String
    init(cursor: String) { self.cursor = cursor }
    mutating func consume(_ event: ControllerCloudRealtimeSSEEvent) throws -> String? {
        if event.name == "keep-alive" { return nil }
        if event.name == "cancel" { throw ControllerCloudRealtimeFailure.permissionDenied }
        if event.name == "auth_revoked" { throw ControllerCloudRealtimeFailure.authenticationRequired }
        guard ["put", "patch"].contains(event.name), event.data.count <= 8_192,
              let wrapper = try? JSONSerialization.jsonObject(with: event.data) as? [String: Any],
              Set(wrapper.keys) == ["path", "data"], let path = wrapper["path"] as? String else {
            throw ControllerCloudRealtimeFailure.invalidResponse
        }
        let allowed: Set<String> = ["schemaVersion", "cursor", "changedAtMs"]
        if path == "/" {
            if wrapper["data"] is NSNull { state = [:]; return nil }
            guard let values = wrapper["data"] as? [String: Any], Set(values.keys).isSubset(of: allowed) else {
                throw ControllerCloudRealtimeFailure.invalidScope
            }
            if event.name == "put" { state = [:] }
            for (key, value) in values { state[key] = value is NSNull ? nil : value }
        } else {
            let key = String(path.dropFirst())
            guard event.name == "put", path == "/" + key, allowed.contains(key) else {
                throw ControllerCloudRealtimeFailure.invalidScope
            }
            state[key] = wrapper["data"] is NSNull ? nil : wrapper["data"]
        }
        if let schema = state["schemaVersion"], integer(schema) != 1 { throw ControllerCloudRealtimeFailure.invalidResponse }
        if let changed = state["changedAtMs"], integer(changed) == nil { throw ControllerCloudRealtimeFailure.invalidResponse }
        if let next = state["cursor"], !(next is String && ControllerCloudRealtimeCursor.valid(next as! String)) {
            throw ControllerCloudRealtimeFailure.invalidResponse
        }
        guard integer(state["schemaVersion"]) == 1, integer(state["changedAtMs"]) != nil,
              let next = state["cursor"] as? String,
              ControllerCloudRealtimeCursor.greater(next, than: cursor) else { return nil }
        return next
    }
    mutating func acknowledge(_ accepted: String) {
        if ControllerCloudRealtimeCursor.valid(accepted), ControllerCloudRealtimeCursor.greater(accepted, than: cursor) { cursor = accepted }
    }
    private func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, String(cString: n.objCType) != "c",
              n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991,
              n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
        return n.int64Value
    }
}
