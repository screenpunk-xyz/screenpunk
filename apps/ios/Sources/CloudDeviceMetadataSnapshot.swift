import Foundation
import ScreenpunkCore
import UIKit
import Darwin

/// Reporting data only: not a claim/profile, installation identity, freshness proof or capability.
struct CloudDeviceMetadataSnapshot: Codable, Equatable, Sendable {
    static let maximumBytes = 4096
    enum Failure: Error, Equatable { case invalidValue, invalidJSON, capacity, unavailableScene }
    enum Provenance: String, Codable, Sendable { case nativeDevice = "native-device", simulator }
    enum InterfaceOrientation: String, Codable, Sendable { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight }
    enum Basis: String, Codable, Sendable {
        case screen = "portrait-normalized-full-screen"
        case viewport = "window-content-bounds"
    }
    struct Measurement: Codable, Equatable, Sendable {
        let width: Double
        let height: Double
        let basis: Basis
        var unit: String { "points" }
        init(width: Double, height: Double, basis: Basis) throws {
            guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 16384, height <= 16384 else { throw Failure.invalidValue }
            self.width = width; self.height = height; self.basis = basis
        }
        private enum CodingKeys: String, CodingKey { case width, height, unit, basis }
        init(from decoder: Decoder) throws {
            try closedKeys(decoder, allowed: ["width", "height", "unit", "basis"], required: ["width", "height", "unit", "basis"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard try c.decode(String.self, forKey: .unit) == "points" else { throw Failure.invalidValue }
            try self.init(width: c.decode(Double.self, forKey: .width), height: c.decode(Double.self, forKey: .height), basis: c.decode(Basis.self, forKey: .basis))
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
            try c.encode(unit, forKey: .unit); try c.encode(basis, forKey: .basis)
        }
    }
    let schemaVersion: Int = 1
    let modelIdentifier: String?
    let modelName: String?
    let deviceName: String?
    let screen: Measurement?
    let viewport: Measurement?
    let interfaceOrientation: InterfaceOrientation?
    let observedAt: String
    let provenance: Provenance

    init(modelIdentifier: String?, modelName: String?, deviceName: String?, screen: Measurement?, viewport: Measurement?,
         interfaceOrientation: InterfaceOrientation?, observedAt: String, provenance: Provenance) throws {
        if let modelIdentifier {
            guard !modelIdentifier.isEmpty, modelIdentifier.utf8.count <= 128,
                  modelIdentifier.utf8.allSatisfy({ (33...126).contains($0) }) else { throw Failure.invalidValue }
        }
        for value in [modelName, deviceName].compactMap({ $0 }) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 256,
                  value.unicodeScalars.count <= 128, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.invalidValue }
        }
        if let screen { guard screen.basis == .screen, screen.width <= screen.height else { throw Failure.invalidValue } }
        if let viewport { guard viewport.basis == .viewport else { throw Failure.invalidValue } }
        guard validUTC(observedAt) else { throw Failure.invalidValue }
        self.modelIdentifier = modelIdentifier; self.modelName = modelName; self.deviceName = deviceName
        self.screen = screen; self.viewport = viewport; self.interfaceOrientation = interfaceOrientation
        self.observedAt = observedAt; self.provenance = provenance
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, modelIdentifier, modelName, deviceName, screen, viewport, interfaceOrientation, observedAt, provenance
        static var all: [String] { ["schemaVersion", "modelIdentifier", "modelName", "deviceName", "screen", "viewport", "interfaceOrientation", "observedAt", "provenance"] }
    }
    init(from decoder: Decoder) throws {
        try closedKeys(decoder, allowed: Set(CodingKeys.all), required: ["schemaVersion", "observedAt", "provenance"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw Failure.invalidValue }
        try self.init(modelIdentifier: c.decodeIfPresent(String.self, forKey: .modelIdentifier), modelName: c.decodeIfPresent(String.self, forKey: .modelName),
                      deviceName: c.decodeIfPresent(String.self, forKey: .deviceName), screen: c.decodeIfPresent(Measurement.self, forKey: .screen),
                      viewport: c.decodeIfPresent(Measurement.self, forKey: .viewport), interfaceOrientation: c.decodeIfPresent(InterfaceOrientation.self, forKey: .interfaceOrientation),
                      observedAt: c.decode(String.self, forKey: .observedAt), provenance: c.decode(Provenance.self, forKey: .provenance))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        // Explicit nulls make each observation a complete replacement, not a merge patch.
        try c.encode(modelIdentifier, forKey: .modelIdentifier); try c.encode(modelName, forKey: .modelName)
        try c.encode(deviceName, forKey: .deviceName); try c.encode(screen, forKey: .screen); try c.encode(viewport, forKey: .viewport)
        try c.encode(interfaceOrientation, forKey: .interfaceOrientation); try c.encode(observedAt, forKey: .observedAt); try c.encode(provenance, forKey: .provenance)
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw Failure.capacity }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw Failure.capacity }
        guard String(data: data, encoding: .utf8) != nil else { throw Failure.invalidJSON }
        var scan = MetadataJSONScan(bytes: Array(data)); try scan.validate()
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw Failure.invalidValue }
    }
}

/// UTC-only reporting spelling, bounded before any date formatter; not the lifecycle wire parser.
private func validUTC(_ value: String) -> Bool {
    let b = Array(value.utf8.prefix(31))
    guard (20...30).contains(b.count), b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58, b.last == 90 else { return false }
    func number(_ start: Int, _ length: Int) -> Int? {
        let slice = b[start..<(start + length)]; guard slice.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return slice.reduce(0) { $0 * 10 + Int($1 - 48) }
    }
    guard let y = number(0, 4), y > 0, let m = number(5, 2), (1...12).contains(m), let d = number(8, 2),
          let h = number(11, 2), h < 24, let minute = number(14, 2), minute < 60, let s = number(17, 2), s < 60 else { return false }
    let days = [31, (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard d > 0, d <= days[m - 1] else { return false }
    return b.count == 20 || (b[19] == 46 && b.count >= 22 && b[20..<(b.count - 1)].allSatisfy({ (48...57).contains($0) }))
}

private struct MetadataKey: CodingKey {
    let stringValue: String; var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func closedKeys(_ decoder: Decoder, allowed: Set<String>, required: Set<String>) throws {
    let keys = Set(try decoder.container(keyedBy: MetadataKey.self).allKeys.map(\.stringValue))
    guard keys.isSubset(of: allowed), required.isSubset(of: keys) else { throw CloudDeviceMetadataSnapshot.Failure.invalidValue }
}

/// Small duplicate-key/depth/node preflight for this object-only, 4KiB schema. JSONDecoder validates values.
private struct MetadataJSONScan {
    let bytes: [UInt8]; var index = 0; var nodes = 0
    mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func consume(_ byte: UInt8) -> Bool { whitespace(); guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
    mutating func string() throws -> String {
        whitespace(); let start = index
        guard consume(34) else { throw CloudDeviceMetadataSnapshot.Failure.invalidJSON }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw CloudDeviceMetadataSnapshot.Failure.invalidJSON }
                return value
            }
            if byte == 92 { guard index < bytes.count else { break }; index += 1 }
        }
        throw CloudDeviceMetadataSnapshot.Failure.invalidJSON
    }
    mutating func value(depth: Int) throws {
        nodes += 1; guard nodes <= 64, depth <= 8 else { throw CloudDeviceMetadataSnapshot.Failure.capacity }
        whitespace(); guard index < bytes.count else { throw CloudDeviceMetadataSnapshot.Failure.invalidJSON }
        if bytes[index] == 123 {
            index += 1; var keys = Set<String>(); if consume(125) { return }
            repeat {
                let key = try string(); guard keys.insert(key).inserted, consume(58) else { throw CloudDeviceMetadataSnapshot.Failure.invalidJSON }
                try value(depth: depth + 1)
                if consume(125) { return }
            } while consume(44)
            throw CloudDeviceMetadataSnapshot.Failure.invalidJSON
        }
        if bytes[index] == 34 { _ = try string(); return }
        let start = index
        while index < bytes.count && ![9, 10, 13, 32, 44, 125].contains(bytes[index]) { index += 1 }
        guard index > start else { throw CloudDeviceMetadataSnapshot.Failure.invalidJSON }
        // Arrays and any malformed primitive are rejected by the actual typed decoder.
    }
    mutating func validate() throws { try value(depth: 0); whitespace(); guard index == bytes.count else { throw CloudDeviceMetadataSnapshot.Failure.invalidJSON } }
}

@MainActor
enum CloudDeviceMetadataCollector {
    struct Observation {
        let modelIdentifier: String?; let mappedModelName: String?; let deviceName: String?
        let screenSize: CGSize?; let contentSize: CGSize?
        let orientation: CloudDeviceMetadataSnapshot.InterfaceOrientation?
        let capturedAt: Date; let provenance: CloudDeviceMetadataSnapshot.Provenance
    }
    /// No live source is read by construction or by the synthetic observation seam.
    static func snapshot(_ observation: Observation) throws -> CloudDeviceMetadataSnapshot {
        func measurement(_ size: CGSize?, basis: CloudDeviceMetadataSnapshot.Basis) throws -> CloudDeviceMetadataSnapshot.Measurement? {
            guard let size else { return nil }
            let width = Double(size.width), height = Double(size.height)
            guard width.isFinite, height.isFinite, width >= 0, height >= 0, width <= 16384, height <= 16384 else { throw CloudDeviceMetadataSnapshot.Failure.invalidValue }
            if width == 0 || height == 0 { return nil } // An unattached layout has no measured viewport.
            return try .init(width: basis == .screen ? min(width, height) : width,
                             height: basis == .screen ? max(width, height) : height, basis: basis)
        }
        guard observation.capturedAt.timeIntervalSince1970.isFinite else { throw CloudDeviceMetadataSnapshot.Failure.invalidValue }
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try .init(modelIdentifier: observation.modelIdentifier, modelName: observation.mappedModelName,
                         deviceName: DeviceDisplayName.sanitize(observation.deviceName), screen: measurement(observation.screenSize, basis: .screen),
                         viewport: measurement(observation.contentSize, basis: .viewport), interfaceOrientation: observation.orientation,
                         observedAt: formatter.string(from: observation.capturedAt), provenance: observation.provenance)
    }
    /// Explicit future action only. The optional marketing name must come from the genuine existing lookup;
    /// this unmounted file deliberately copies no hardware table and supplies no guessed fallback.
    static func capture(window: UIWindow, contentBounds: CGRect?, capturedAt: Date, mappedModelName: String?) throws -> CloudDeviceMetadataSnapshot {
        guard let scene = window.windowScene else { throw CloudDeviceMetadataSnapshot.Failure.unavailableScene }
        var system = utsname(); let success = uname(&system) == 0
        let raw: String? = success ? withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        } : nil
#if targetEnvironment(simulator)
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        let provenance = CloudDeviceMetadataSnapshot.Provenance.simulator
#else
        let identifier = raw
        let provenance = CloudDeviceMetadataSnapshot.Provenance.nativeDevice
#endif
        let orientation: CloudDeviceMetadataSnapshot.InterfaceOrientation?
        switch scene.interfaceOrientation {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: orientation = nil
        }
        return try snapshot(.init(modelIdentifier: identifier, mappedModelName: mappedModelName, deviceName: UIDevice.current.name,
                                  screenSize: scene.screen.bounds.size, contentSize: contentBounds?.size, orientation: orientation,
                                  capturedAt: capturedAt, provenance: provenance))
    }
}
