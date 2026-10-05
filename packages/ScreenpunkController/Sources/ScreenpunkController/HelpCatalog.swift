import Foundation
import ScreenpunkCore

public struct HelpTopic: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
}

public enum HelpCatalog: Sendable {
    public static let unlinkGesture =
        "Hold two fingers on the device screen for five seconds to open the device menu, then choose Disconnect and confirm. Opening the menu does not erase anything. Confirming Disconnect erases screens, credentials, and pairing."

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
        if let url = BundledResources.url(forResource: "help", withExtension: "json"),
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
            "home-assistant": HelpTopic(id: "home-assistant", title: "Home Assistant service calls", body: "Declare home.serviceCalls in connections: [{alias:'home',required:true,serviceCalls:[{domain:'light',service:'turn_on',entityIds:['light.example']}]}]. Then use screenpunk.homeAssistant.callService({domain:'light',service:'turn_on',target:{entity_id:'light.example'},serviceData:{rgb_color:[255,0,0],transition:1}}). The SDK accepts nested JSON and returns {value:null,stale:false} after success. Poll connections.request('home','getStates',{}) first; disable writes on stale, unavailable, or failed reads. Native hosts reject writes without fresh state (45 seconds). Writes are never queued or replayed. Inspect home with query services: or services:light to discover HA services and fields. Service names and targets must match installed declarations. Explicit allowUntargeted:true permits omission of target for services such as notifications or direct script calls. No wildcard, area, device, label or floor targets; do not put target keys in serviceData. Declarations authorize the full semantics of a service, including script effects and services which ignore targets; Home Assistant remains the permission authority. Calls are limited to 32 KiB JSON, 12 nested data levels, 2048 values, and 8192 bytes per string. Old screens retain named operations including mediaOn/mediaOff and lightOn rgb_color. Screens declaring serviceCalls restrict legacy aliases too. New declarations require home-assistant-services-v1 hosts, but iOS/iPadOS minimum remains 16. Credentials stay native and destinations/TLS checks remain enforced. Apply installs revision-bound declarations; live previews use the same declarations."),
            "authoring": HelpTopic(id: "authoring", title: "Package-local CSS and JavaScript", body: "The native host requires package-local CSS and JavaScript: style-src 'self' and script-src 'self'. Put CSS in styles.css and link it with <link rel=\"stylesheet\" href=\"styles.css\">; put executable JavaScript in app.js and load <script src=\"app.js\"></script>. Include both files in the package. Inline <style>, style attributes, executable inline <script> and inline event handlers are blocked; use classes and addEventListener in bundled code. JSON data blocks are inert. React builds already emit screen.css and screen.js; retain CSS imports and compiled module code. Do not weaken CSP or modify a retained kit. Use shipped tools/list schemas: inspect_workspace_project(projectId), get_workspace_source_file(projectId,path,expectedSourceVersion,offset), patch_workspace_project(projectId,expectedSourceVersion,changes:[{path,bytesBase64}]), get_workspace_build(projectId), run_workspace_build(projectId,expectedSourceVersion,baseRevision). Patch actual included members with canonical base64; preserve source CAS and existing settings/declarations. Read built bytes with get_workspace_package_file(dashboardId,revision,path,offset); empty path selects the manifest. get_dashboard is a summary, not file content. validate_dashboard reports static authoring diagnostics; it does not prove rendering. If preview_dashboard reports preview_required, preserve that failure. Inspect the exact revision through a supported visual review, then prepare/plan/review and obtain matching human approval before apply_deployment. Changed bytes need a new plan and approval. See docs/web-package-authoring.md and examples/local-web-package."),
            "onboarding": HelpTopic(
                id: "onboarding",
                title: "Screenpunk MCP",
                body: """
                Screenpunk starts its local controller and hidden preview helper automatically when this MCP server launches. The Mac workbench does not need to be visibly open.

                Author screens with package-local CSS and JavaScript, never inline style/script. Read get_help(topic: authoring) before creating or changing a screen.

                Preview is live by default. Actions in a live preview can control approved devices. Screenshot capture itself does not click controls.

                Device recovery: hold two fingers on the device screen for five seconds to open the device menu, then choose Disconnect and confirm. Only confirming Disconnect erases screens, credentials, and pairing. Forgetting an unreachable device on the Mac does not erase it.
                """
            ),
            "unlink": HelpTopic(
                id: "unlink",
                title: "Disconnect a device",
                body: """
                \(unlinkGesture)

                \(forgetDoesNotErase) This Mac has forgotten the device. To remove its screens and pairing, hold two fingers on its screen for five seconds to open the device menu, then choose Disconnect and confirm.
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
