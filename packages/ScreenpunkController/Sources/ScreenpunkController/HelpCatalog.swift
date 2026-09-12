import Foundation
import ScreenpunkCore

public struct HelpTopic: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
}

public enum HelpCatalog: Sendable {
    public static let unlinkGesture =
        "Hold two fingers on the device screen for ten seconds, then tap Unlink. Dashboard, credentials, and pairing are erased."

    public static let forgetDoesNotErase =
        "Forgetting an unreachable device on the Mac does not erase it."

    public static let livePreviewLabel = "Live preview — actions control your devices"

    public static let onboardingInstructions: String = {
        topic(id: "onboarding").body
    }()

    public static func topic(id: String) -> HelpTopic {
        let topics = loadTopics()
        if let match = topics[id.lowercased()] {
            return match
        }
        let index = topics.keys.sorted().map { "- \($0): \(topics[$0]!.title)" }.joined(separator: "\n")
        return HelpTopic(
            id: "index",
            title: "Screenpunk help",
            body: "Unknown topic \(id). Available topics:\n\(index)\n\n\(unlinkGesture)\n\(forgetDoesNotErase)"
        )
    }

    public static func loadTopics() -> [String: HelpTopic] {
        if let url = Bundle.module.url(forResource: "help", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        {
            var topics: [String: HelpTopic] = [:]
            for (key, value) in parsed {
                topics[key] = HelpTopic(
                    id: key,
                    title: value["title"] ?? key,
                    body: value["body"] ?? ""
                )
            }
            return topics
        }
        return fallbackTopics()
    }

    public static func fallbackTopics() -> [String: HelpTopic] {
        [
            "onboarding": HelpTopic(
                id: "onboarding",
                title: "Screenpunk MCP",
                body: """
                Screenpunk starts its local controller and hidden preview helper automatically when this MCP server launches. The Mac workbench does not need to be visibly open.

                Preview is live by default. Actions in a live preview can control approved devices. Screenshot capture itself does not click controls.

                Unlink recovery: hold two fingers on the device screen for ten seconds, then tap Unlink. Dashboard, credentials, and pairing are erased. Forgetting an unreachable device on the Mac does not erase it.
                """
            ),
            "unlink": HelpTopic(
                id: "unlink",
                title: "Unlink a device",
                body: """
                \(unlinkGesture)

                \(forgetDoesNotErase) This Mac has forgotten the device. To remove its dashboard and pairing, hold two fingers on its screen for 10 seconds, then tap Unlink.
                """
            ),
            "preview": HelpTopic(
                id: "preview",
                title: "Live preview",
                body: """
                preview_dashboard returns PNG image content rendered by Screenpunk's hidden helper. \(livePreviewLabel). Preview is live by default. Failed captures are errors, not placeholder images.
                """
            ),
            "pairing": HelpTopic(
                id: "pairing",
                title: "Pairing",
                body: """
                A device allows one owner. request_pairing returns a six-digit matching code over the TLS 1.3 LAN link; the user compares it with the device screen and taps Confirm on the device, then confirm_pairing completes. Pairing and new connections never self-approve through MCP. forget_device does not erase the device.
                """
            ),
            "deploy": HelpTopic(
                id: "deploy",
                title: "Deploy",
                body: """
                deploy_dashboard ships the exact previewed revision the user approved in chat (approved=true). A failed transfer keeps the device's current dashboard. Idempotent on deploymentId. The Mac is not a runtime proxy.
                """
            )
        ]
    }

    public static var unlinkHoldsSeconds: Int { UnlinkGestureSpec.holdSeconds }
    public static var unlinkFingers: Int { UnlinkGestureSpec.fingers }
}
