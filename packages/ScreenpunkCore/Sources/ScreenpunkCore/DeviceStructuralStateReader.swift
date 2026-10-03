import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Pure interpretation of caller-supplied evidence; never enumerates or writes files.
/// Structural: 64 KiB / 4096 values. Legacy: 4 MiB / 65536 values. Both depth 32.
/// Oversized legitimate legacy state blocks without truncation or implied migration.
public enum DeviceStructuralStateReader {
    public static func read(structural: DeviceStructuralInput, legacy: DeviceStructuralInput,
        expectation: DeviceStructuralBindingExpectation, packages: [DeviceStructuralPackageEvidence]) -> DeviceStructuralRead {
        do {
            switch structural {
            case .readError: throw DeviceStructuralReadFailure.readError
            case .bytes(let bytes):
                let object = try parse(bytes, limit: 64 * 1024, nodes: 4096)
                try shape(object, .snapshot)
                let snapshot = try JSONDecoder().decode(DeviceStructuralSnapshot.self, from: bytes)
                guard snapshot.schemaVersion == 1 else { throw DeviceStructuralReadFailure.unsupportedSchema }
                if case .bound(let expected) = expectation, snapshot.generationID != expected { throw DeviceStructuralReadFailure.invalidState }
                try validate(snapshot, packages)
                return .bound(snapshot)
            case .missing:
                if case .bound = expectation { throw DeviceStructuralReadFailure.missingBinding }
            }
            switch legacy {
            case .readError: throw DeviceStructuralReadFailure.readError
            case .missing:
                guard packages.isEmpty else { throw DeviceStructuralReadFailure.packageMismatch }
                return .absent
            case .bytes(let bytes):
                let object = try parse(bytes, limit: 4 * 1024 * 1024, nodes: 65536)
                try shape(object, .legacy)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(DevicePersistedState.self, from: bytes)
                try state.settings?.value.validate()
                let kind: LegacyContentEvidence.Kind
                if let set = state.screenSet {
                    guard (1...12).contains(set.screens.count), Set(set.screens.map { $0.revision.dashboardId }).count == set.screens.count,
                          Set(set.screens.map { $0.revision.revision }).count == set.screens.count,
                          bounded(set.grantSet), bounded(set.deploymentId), bounded(set.contentDigest),
                          let selected = set.screens.first(where: { $0.revision.dashboardId == set.selectedDashboardId }),
                          state.activeStoredRevision == selected.revision, state.activeRevision == selected.revision.revision,
                          state.lastDeployment == selected.deployment else { throw DeviceStructuralReadFailure.invalidState }
                    // Deployed selection can refer to a locally removed screen; preserve it as historical evidence.
                    for entry in set.screens {
                        try revision(entry.revision)
                        guard bounded(entry.name), entry.deployment.dashboardId == entry.revision.dashboardId,
                              entry.deployment.revision == entry.revision.revision, entry.deployment.phase == .active else { throw DeviceStructuralReadFailure.invalidState }
                    }
                    try match(set.screens.map { .init(directory: $0.packageDirectory, revision: $0.revision) }, packages)
                    kind = .orderedSet
                } else if let stored = state.activeStoredRevision {
                    try revision(stored)
                    guard state.activeRevision == stored.revision, let deployment = state.lastDeployment,
                          deployment.dashboardId == stored.dashboardId, deployment.revision == stored.revision,
                          deployment.phase == .active else { throw DeviceStructuralReadFailure.invalidState }
                    try match([.init(directory: "package", revision: stored)], packages)
                    kind = .singlePackage
                } else {
                    guard state.activeRevision == nil, state.lastDeployment == nil, packages.isEmpty else { throw DeviceStructuralReadFailure.packageMismatch }
                    kind = .empty
                }
                for owner in [state.owner, state.contentOwner].compactMap({ $0 }) {
                    guard owner.role == .controller, owner.isWellFormed else { throw DeviceStructuralReadFailure.invalidState }
                }
                return .legacyUnbound(.init(kind: kind, originalBytes: bytes, originalSHA256: try exactHash(bytes), state: state))
            }
        } catch let failure as DeviceStructuralReadFailure { return .blocked(failure) }
        catch { return .blocked(.invalidJSON) }
    }

    private static func exactHash(_ bytes: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #else
        // Existing PeerPin's non-CryptoKit prefix fallback is not a cryptographic digest.
        throw DeviceStructuralReadFailure.digestUnavailable
        #endif
    }
    private static func bounded(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 32 } }
    private static func directory(_ value: String) -> Bool {
        bounded(value) && (value == "package" || (value.hasPrefix("package.staging-") && !value.contains("/") && !value.contains("..")))
    }
    private static func revision(_ value: StoredRevision) throws {
        guard bounded(value.dashboardId), bounded(value.revision), bounded(value.name), bounded(value.digest), value.width > 0, value.height > 0 else { throw DeviceStructuralReadFailure.invalidState }
    }
    private static func match(_ required: [DeviceStructuralPackageEvidence], _ supplied: [DeviceStructuralPackageEvidence]) throws {
        guard required.count <= 12, supplied.count <= 12, required.count == supplied.count,
              Set(required.map(\.directory)).count == required.count, Set(supplied.map(\.directory)).count == supplied.count,
              required.allSatisfy({ directory($0.directory) && supplied.contains($0) }) else { throw DeviceStructuralReadFailure.packageMismatch }
    }
    private static func validate(_ state: DeviceStructuralSnapshot, _ packages: [DeviceStructuralPackageEvidence]) throws {
        guard state.entries.count <= 12, Set(state.entries.map(\.entryID)).count == state.entries.count,
              Set(state.entries.map { $0.revision.dashboardId }).count == state.entries.count,
              state.entries.isEmpty ? state.configuredEntryID == nil : state.entries.contains(where: { $0.entryID == state.configuredEntryID }),
              state.grantSet.map(bounded) ?? true else { throw DeviceStructuralReadFailure.invalidState }
        if let owner = state.contentOwner { guard owner.role == .controller, owner.isWellFormed else { throw DeviceStructuralReadFailure.invalidState } }
        for entry in state.entries {
            guard bounded(entry.displayName) else { throw DeviceStructuralReadFailure.invalidState }
            try revision(entry.revision)
        }
        try match(state.entries.map { .init(directory: $0.packageDirectory, revision: $0.revision) }, packages)
    }

    private enum Shape { case snapshot, entry, revision, owner, legacy, set, installed, deployment, settings, values, brightness, schedule, rules, ruleMap, rule, stringMap }
    private static func shape(_ object: Any, _ type: Shape) throws {
        if object is NSNull { return }
        guard let map = object as? [String: Any] else { throw DeviceStructuralReadFailure.invalidJSON }
        let keys: Set<String>
        switch type {
        case .snapshot: keys = ["schemaVersion","generationID","entries","configuredEntryID","contentOwner","grantSet"]
        case .entry: keys = ["entryID","provenance","displayName","revision","packageDirectory"]
        case .revision: keys = ["revision","dashboardId","name","digest","orientation","width","height"]
        case .owner: keys = ["role","publicKey"]
        case .legacy: keys = ["owner","activeRevision","activeStoredRevision","lastDeployment","screenSet","settings","contentOwner","savedAt"]
        case .set: keys = ["deploymentId","contentDigest","deployedSelectedDashboardId","grantSet","screens","selectedDashboardId"]
        case .installed: keys = ["name","revision","deployment","packageDirectory"]
        case .deployment: keys = ["deploymentId","revision","dashboardId","deviceId","phase","error"]
        case .settings: keys = ["revision","value","appliedRevision"]
        case .values: keys = ["displayName","startingPageByDashboard","brightness","eventRuleOverrides"]
        case .brightness: keys = ["mode","fixedLevel","schedule"]
        case .schedule: keys = ["minuteOfDay","level"]
        case .rule: keys = ["enabled","pageId","returnBehavior","timeoutSeconds","allowPayloadOverrides"]
        case .rules, .ruleMap, .stringMap: keys = Set(map.keys)
        }
        guard Set(map.keys).isSubset(of: keys) else { throw DeviceStructuralReadFailure.invalidJSON }
        for (key, value) in map {
            let child: Shape?
            switch (type, key) {
            case (.snapshot,"entries"): child = .entry
            case (.snapshot,"contentOwner"), (.legacy,"owner"), (.legacy,"contentOwner"): child = .owner
            case (.entry,"revision"), (.installed,"revision"), (.legacy,"activeStoredRevision"): child = .revision
            case (.installed,"deployment"), (.legacy,"lastDeployment"): child = .deployment
            case (.legacy,"screenSet"): child = .set
            case (.set,"screens"): child = .installed
            case (.legacy,"settings"): child = .settings
            case (.settings,"value"): child = .values
            case (.values,"brightness"): child = .brightness
            case (.brightness,"schedule"): child = .schedule
            case (.values,"startingPageByDashboard"): child = .stringMap
            case (.values,"eventRuleOverrides"): child = .rules
            case (.rules,_): child = .ruleMap
            case (.ruleMap,_): child = .rule
            default: child = nil
            }
            if let child {
                if let array = value as? [Any] { for item in array { try shape(item, child) } }
                else { try shape(value, child) }
            }
        }
    }

    private static func parse(_ data: Data, limit: Int, nodes: Int) throws -> Any {
        guard data.count <= limit else { throw DeviceStructuralReadFailure.oversized }
        guard String(data: data, encoding: .utf8) != nil else { throw DeviceStructuralReadFailure.invalidJSON }
        var scanner = Preflight(bytes: Array(data), remaining: nodes)
        try scanner.value(depth: 0); scanner.space()
        guard scanner.index == scanner.bytes.count else { throw DeviceStructuralReadFailure.invalidJSON }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Schema-local lexical preflight prevents Foundation's duplicate-key collapse and surrogate replacement.
    private struct Preflight {
        let bytes: [UInt8]; var remaining: Int; var index = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func require(_ byte: UInt8) throws { guard index < bytes.count, bytes[index] == byte else { throw DeviceStructuralReadFailure.invalidJSON }; index += 1 }
        mutating func value(depth: Int) throws {
            space(); remaining -= 1
            guard depth <= 32, remaining >= 0, index < bytes.count else { throw DeviceStructuralReadFailure.invalidJSON }
            switch bytes[index] {
            case 123:
                index += 1; space(); var keys = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string(); guard keys.insert(key).inserted else { throw DeviceStructuralReadFailure.invalidJSON }
                    space(); try require(58); try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 125 { index += 1; return }
                    try require(44); space()
                }
            case 91:
                index += 1; space()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 93 { index += 1; return }
                    try require(44)
                }
            case 34: _ = try string()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            default:
                let start = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                guard text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw DeviceStructuralReadFailure.invalidJSON }
            }
        }
        mutating func literal(_ value: String) throws { for byte in value.utf8 { try require(byte) } }
        mutating func hex() throws -> UInt16 {
            var result: UInt16 = 0
            for _ in 0..<4 {
                guard index < bytes.count else { throw DeviceStructuralReadFailure.invalidJSON }
                let byte = bytes[index]; index += 1
                let value: UInt16
                switch byte { case 48...57: value = UInt16(byte-48); case 65...70: value = UInt16(byte-55); case 97...102: value = UInt16(byte-87); default: throw DeviceStructuralReadFailure.invalidJSON }
                result = result * 16 + value
            }
            return result
        }
        mutating func string() throws -> String {
            let start = index; try require(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                guard byte >= 32 else { throw DeviceStructuralReadFailure.invalidJSON }
                if byte == 92 {
                    guard index < bytes.count else { throw DeviceStructuralReadFailure.invalidJSON }
                    let escape = bytes[index]; index += 1
                    if escape == 117 {
                        let scalar = try hex()
                        if (0xD800...0xDBFF).contains(scalar) {
                            try require(92); try require(117); let low = try hex()
                            guard (0xDC00...0xDFFF).contains(low) else { throw DeviceStructuralReadFailure.invalidJSON }
                        } else if (0xDC00...0xDFFF).contains(scalar) { throw DeviceStructuralReadFailure.invalidJSON }
                    } else if ![34,92,47,98,102,110,114,116].contains(escape) { throw DeviceStructuralReadFailure.invalidJSON }
                }
            }
            throw DeviceStructuralReadFailure.invalidJSON
        }
    }
}
