import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Agreed candidate byte profiles only, separate from durable structural Codable.
/// These digests identify supplied bytes; they do not authenticate or admit them.
enum DeviceDeliveryCandidateCodec {
    static let observationProfile = "screenpunk-device-delivery-v1"
    static let resultingSetProfile = "screenpunk-device-resulting-set-v1"
    static let maximumEncodedBytes = 8192
    // Maximum legal cloud entry:44+13+37+5*44+3*72+16+16+12 =574 bytes.
    // Observation:30+132+9+10+12*574+56=7125. Result:35+9+10+12*574+56=6998.
    static let maximumObservationBytes = 7125
    static let maximumResultingSetBytes = 6998

    static func observationBytes(_ input: DeviceDeliveryObservationCandidate) throws -> Data {
        try encode(profile: observationProfile,
            frames: ["1", uuid(input.installationID), uuid(input.transitionID), uuid(input.generationID)] + setFrames(input.resultingSet))
    }
    static func resultingSetBytes(_ input: DeviceResultingSetCandidate) throws -> Data {
        try encode(profile: resultingSetProfile, frames: ["1"] + setFrames(input))
    }
    static func observationDigest(_ input: DeviceDeliveryObservationCandidate) throws -> String {
        try digest(observationBytes(input))
    }
    static func resultingSetDigest(_ input: DeviceResultingSetCandidate) throws -> String {
        try digest(resultingSetBytes(input))
    }
    private static func uuid(_ input: UUID) -> String { input.uuidString.lowercased() }
    private static func setFrames(_ input: DeviceResultingSetCandidate) -> [String] {
        var frames = [String(input.entries.count)]
        for entry in input.entries {
            frames.append(uuid(entry.entryID))
            switch entry.provenance {
            case .cloud(let p):
                frames += ["cloud", DeviceDeliveryPackageCandidate.profile, uuid(p.publicationID), uuid(p.projectID),
                    uuid(p.packageID), uuid(p.dashboardID), uuid(p.revision), p.manifestDigest.text,
                    p.manifestSHA256.text, p.archiveSHA256.text, String(p.compressedBytes),
                    String(p.expandedBytes), String(p.archiveEntries)]
            case .retainedLocal(let reference, let hash):
                frames += ["retainedLocal", uuid(reference), hash.text]
            }
        }
        if let selected = input.configuredEntryID { frames += ["uuid", uuid(selected)] }
        else { frames.append("null") }
        return frames
    }
    private static func encode(profile: String, frames: [String]) throws -> Data {
        var count = profile.utf8.count + 1
        for frame in frames {
            let length = frame.utf8.count
            guard length <= maximumEncodedBytes - count - 8 else { throw DeviceDeliveryCandidateFailure.sizeLimit }
            count += 8 + length
        }
        // Typed field/collection limits bound frames before this allocation.
        var output = Data(); output.reserveCapacity(count)
        output.append(contentsOf: profile.utf8); output.append(0)
        for frame in frames {
            var length = UInt64(frame.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(contentsOf: frame.utf8)
        }
        guard output.count == count, output.count <= maximumEncodedBytes else { throw DeviceDeliveryCandidateFailure.sizeLimit }
        return output
    }
    private static func digest(_ bytes: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #else
        throw DeviceDeliveryCandidateFailure.digestUnavailable
        #endif
    }
}
