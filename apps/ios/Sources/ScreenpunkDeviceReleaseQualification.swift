import Foundation

/// Build-owned permission for an internal staging qualification candidate.
/// This never records physical qualification and cannot be enabled by sign-in.
enum ScreenpunkDeviceReleaseQualification {
    static var concurrentControl: Bool {
        #if SCREENPUNK_INTERNAL_STAGING_CONCURRENT_CANDIDATE
        candidateAllows(info: Bundle.main.infoDictionary ?? [:], bundleID: Bundle.main.bundleIdentifier)
        #elseif SCREENPUNK_CONCURRENT_CONTROL_QUALIFIED
        true
        #else
        false
        #endif
    }

    static func candidateAllows(info: [String: Any], bundleID: String?) -> Bool {
        guard info["ScreenpunkInternalConcurrentControlCandidate"] as? String == "internal-staging-concurrent-v1",
              info["ScreenpunkConcurrentControlBuildMode"] as? String == "internal-staging-candidate",
              info["ScreenpunkConcurrentControlCompileFlag"] as? String == "SCREENPUNK_INTERNAL_STAGING_CONCURRENT_CANDIDATE",
              bundleID == "xyz.screenpunk.ios",
              let configuration = try? CloudNativeConfiguration.load(info: info, bundleID: bundleID),
              configuration.projectID == "screenpunk-stg-6f6e615a",
              configuration.apiOrigin.absoluteString == "https://staging.screenpunk.xyz" else { return false }
        return true
    }
}
