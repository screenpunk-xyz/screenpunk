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
            "service": HelpTopic(id: "service", title: "Start the Mac CLI service", body: "macOS may display a permission or security prompt during the first service start after an install or update. Review it and approve the appropriate prompt for your verified Screenpunk installation. An agent must surface a pending prompt early and wait for you; it cannot dismiss or approve an OS prompt on your behalf.\n\nAfter resolving a pending prompt, retry once with screenpunk service start --json, outside the Codex sandbox through its normal approval flow, using the same installing account without sudo. If it still fails, preserve the complete command, JSON error, stdout/stderr and exit status. Collect screenpunk service logs --json and launchctl print gui/<your UID>/com.screenpunk.workbench before another start or recovery attempt. The UID must be the installing account's effective UID. These diagnostics do not start the broker.\n\nKeep activationError and cleanupError separate. One Studio 1.0.8 start reported activationError=unavailable and cleanupError=insecureRuntime, then worked after the user allowed a pending macOS prompt. The prompt text and precise cause were not established; these errors do not identify a particular macOS permission.\n\nPreserve the workspace, pairing, saved screen preferences and local drafts. Do not reset them, change runtime permissions, delete sockets, bypass ownership guards or delete Keychain entries to get past startup. Review the diagnostic evidence before choosing a supported recovery."),
            "persistent-state": HelpTopic(id: "persistent-state", title: "Preserve screen user data", body: "Every screen that accepts user-entered data or preferences should durably persist them with the injected native screenpunk.state.get/set/remove so ordinary screen updates and app relaunches preserve them. Keep manifest dashboardId and stable versioned keys across revisions; store one small JSON object with schemaVersion. Observe runtime.onStatus while active and require persistentState:1, persistentStateWritable:1 and state methods before durable editing. Report unsupported/read-only hosts instead of silently using volatile storage. Read and validate saved data before enabling controls or defaulting missing fields. Never set defaults on load/update, after a failed read or over an unknown schema; migrate known schemas without discarding user values. Save explicit edits with awaited serialized/debounced writes and visible read/save failures. Reset only on explicit user action. Values are device-local, not remotely readable through CLI/MCP and not cross-device sync. Hidden Mac preview is read-only and independent from iPhone state; offline preview has no native persistence. Do not promise survival of app removal, device reset or confirmed Disconnect. Validate a distinctive saved value through an app close/reopen and a newly approved appearance-only screen revision retaining dashboardId/key/schema. Key <=256 UTF8 bytes, JSON value <=16KiB/depth16; no credentials, service responses or private event caches. See docs/screen-authoring-persistence.md and docs/connections/local-screen-state.md. Capability-aware source can be authored before phone support is known; confirm flags on the active screen without inventing management capability commands or reading private device files. ## State API result shapes `await screenpunk.state.get(key)` returns the saved JSON value **directly**, or null for a missing key/stored null; it does not return a {value, stale} envelope. `await screenpunk.state.set(key, value)` and `await screenpunk.state.remove(key)` resolve to undefined on success (`Promise<void>`). Do not use a truthiness check on their return value to decide whether saving worked. All three reject on errors; catch the SDK error/code, show a failure, and do not overwrite with defaults. A timeout or disk failure can leave write outcome uncertain: do not claim Saved or blindly replay; restore/inspect through the supported screen API later. `screenpunk.runtime.onStatus(listener)` subscribes and returns an unsubscribe function. The listener receives the status object directly. active is a boolean; persistentState and persistentStateWritable are numeric flags, with support/write permission represented by 1 (not the boolean true). Method existence is not a substitute for those runtime flags. Dispose the listener when the screen unmounts."),
            "home-assistant": HelpTopic(id: "home-assistant", title: "Home Assistant service calls", body: "Declare home.serviceCalls in connections: [{alias:'home',required:true,serviceCalls:[{domain:'light',service:'turn_on',entityIds:['light.example']}]}]. Then use screenpunk.homeAssistant.callService({domain:'light',service:'turn_on',target:{entity_id:'light.example'},serviceData:{rgb_color:[255,0,0],transition:1}}). The SDK accepts nested JSON and returns {value:null,stale:false} after success. Poll connections.request('home','getStates',{}) first; disable writes on stale, unavailable, or failed reads. Native hosts reject writes without fresh state (45 seconds). Writes are never queued or replayed. Inspect home with query services: or services:light to discover HA services and fields. Service names and targets must match installed declarations. Explicit allowUntargeted:true permits omission of target for services such as notifications or direct script calls. No wildcard, area, device, label or floor targets; do not put target keys in serviceData. Declarations authorize the full semantics of a service, including script effects and services which ignore targets; Home Assistant remains the permission authority. Calls are limited to 32 KiB JSON, 12 nested data levels, 2048 values, and 8192 bytes per string. Old screens retain named operations including mediaOn/mediaOff and lightOn rgb_color. Screens declaring serviceCalls restrict legacy aliases too. New declarations require home-assistant-services-v1 hosts, but iOS/iPadOS minimum remains 16. Credentials stay native and destinations/TLS checks remain enforced. Apply installs revision-bound declarations; live previews use the same declarations."),
            "authoring": HelpTopic(id: "authoring", title: "Package-local CSS and JavaScript", body: "The native host requires package-local CSS and JavaScript: style-src 'self' and script-src 'self'. Put CSS in styles.css and link it with <link rel=\"stylesheet\" href=\"styles.css\">; put executable JavaScript in app.js and load <script src=\"app.js\"></script>. Include both files in the package. Inline <style>, style attributes, executable inline <script> and inline event handlers are blocked; use classes and addEventListener in bundled code. JSON data blocks are inert. React builds already emit screen.css and screen.js; retain CSS imports and compiled module code. Do not weaken CSP or modify a retained kit. Use shipped tools/list schemas: inspect_workspace_project(projectId), get_workspace_source_file(projectId,path,expectedSourceVersion,offset), patch_workspace_project(projectId,expectedSourceVersion,changes:[{path,bytesBase64}]), get_workspace_build(projectId), run_workspace_build(projectId,expectedSourceVersion,baseRevision). Patch actual included members with canonical base64; preserve source CAS and existing settings/declarations. Read built bytes with get_workspace_package_file(dashboardId,revision,path,offset); empty path selects the manifest. get_dashboard is a summary, not file content. validate_dashboard reports static authoring diagnostics; it does not prove rendering. If preview_dashboard reports preview_required, preserve that failure. Inspect the exact revision through a supported visual review, then prepare/plan/review and obtain matching human approval before apply_deployment. Changed bytes need a new plan and approval. See docs/web-package-authoring.md and examples/local-web-package."),
            "onboarding": HelpTopic(
                id: "onboarding",
                title: "Screenpunk MCP",
                body: """
                Screenpunk starts its local controller and hidden preview helper automatically when this MCP server launches. The Mac workbench does not need to be visibly open.

                macOS may display a permission or security prompt during the first service start after an install or update. Surface a pending prompt early and wait for the human to review and approve the appropriate prompt for their verified Screenpunk installation. An agent cannot dismiss or approve the OS prompt on the user's behalf. The exact prompt type is not established by a startup error. Read get_help(topic: service) or offline screenpunk help service for startup troubleshooting.

                Author screens with package-local CSS and JavaScript, never inline style/script. Read get_help(topic: authoring) before creating or changing a screen.

                Every editable screen should preserve user-entered data across ordinary updates. Read get_help(topic: persistent-state) before adding user inputs.

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
