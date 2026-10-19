import AppKit
import Foundation
import ScreenpunkController

enum WorkbenchCloudCLI {
    enum Action: Equatable {
        case login, logout, status, projects
        case workspace(String), link(String, String), sync(String), resolve(String, Bool), unlink(String)
        case restore(String, String), create(String, String)
        case reviewDeployment(String, String), applyDeployment, deviceStatus(String)
        case publish(String)
    }
    static func parse(_ words: [String]) throws -> Action {
        switch Array(words.dropFirst()) {
        case ["login"]: return .login
        case ["logout"]: return .logout
        case ["status"]: return .status
        case ["projects"]: return .projects
        case let values where values.count == 2 && values[0] == "publish": return .publish(values[1])
        case ["deploy", "apply"]: return .applyDeployment
        case let values where values.count == 4 && values[0] == "deploy" && values[1] == "review": return .reviewDeployment(values[2], values[3])
        case let values where values.count == 3 && values[0] == "device" && values[1] == "status": return .deviceStatus(values[2])
        case let values where values.count == 3 && values[0] == "workspace" && values[1] == "select":
            return .workspace(values[2])
        case let values where values.count == 3 && values[0] == "link": return .link(values[1], values[2])
        case let values where values.count == 2 && values[0] == "sync": return .sync(values[1])
        case let values where values.count == 3 && values[0] == "resolve" && ["local", "remote"].contains(values[2]):
            return .resolve(values[1], values[2] == "local")
        case let values where values.count == 2 && values[0] == "unlink": return .unlink(values[1])
        case let values where values.count == 3 && values[0] == "restore": return .restore(values[1], values[2])
        case let values where values.count == 3 && values[0] == "create" && ["html", "react"].contains(values[2]):
            return .create(values[1], values[2])
        default: throw Options.usage("cloud requires login|logout|status|projects|workspace select ID|link LOCAL_ID CLOUD_ID|sync LOCAL_ID|resolve LOCAL_ID local|remote|unlink LOCAL_ID|restore CLOUD_ID NAME|create NAME html|react.")
        }
    }
    static func run(words: [String], options: Options, client: WorkbenchBrokerClient, machineRoot: URL,
                    environment: [String: String], presentation: Presentation) throws {
        let action = try parse(words)
        let configuration: ControllerCloudConfiguration
        do { configuration = try wait { try await .deployment(environment: deploymentEnvironment(environment), machineRoot: machineRoot) } }
        catch {
            throw CommandFailure("cloud_not_configured", "Cloud controller sign-in requires the deployment's registered public OAuth client configuration.", 8,
                nextActions: ["Configure SCREENPUNK_CLOUD_BASE_URL, SCREENPUNK_CLOUD_AUTHORIZATION_URL, SCREENPUNK_CLOUD_TOKEN_URL, SCREENPUNK_CLOUD_REVOCATION_URL, and SCREENPUNK_CLOUD_CLIENT_ID."])
        }
        let cloud = try ControllerCloudWorkbench(configuration: configuration, client: client, machineRoot: machineRoot)
        let result = try wait {
            switch action {
            case .login:
                try await cloud.signIn { url in
                    guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else { throw ControllerCloudError.invalidConfiguration }
                }
                return try encode(await cloud.status())
            case .logout: try await cloud.signOut(); return ["state": "signed_out", "localProjectsPreserved": true]
            case .status: return try encode(await cloud.status())
            case .workspace(let id): try await cloud.selectWorkspace(id); return ["selectedWorkspaceId": id]
            case .projects: return ["items": try await cloud.projects().map { try encode($0) }]
            case .link(let local, let remote): try await cloud.link(localProjectId: local, cloudProjectId: remote); return ["localProjectId": local, "cloudProjectId": remote, "state": "linked"]
            case .sync(let id): return try encode(await cloud.sync(localProjectId: id))
            case .resolve(let id, let local): return try encode(await cloud.sync(localProjectId: id, choice: local ? .local : .remote))
            case .unlink(let id): try await cloud.unlink(localProjectId: id); return ["localProjectId": id, "state": "unlinked", "localProjectsPreserved": true]
            case .restore(let id, let name): return try encode(await cloud.restore(cloudProjectId: id, name: name))
            case .create(let name, let kind): return try encode(await cloud.createProject(name: name, kind: kind))
            case .reviewDeployment(let publication, let installation):
                return try encode(await cloud.reviewDeployment(publicationId: publication, installationId: installation))
            case .applyDeployment:
                guard options.approved, let file = options.inputFile, file.hasPrefix("/") else {
                    throw Options.usage("cloud deploy apply requires --file ABS_REVIEW_JSON --approved after reviewing the exact resulting screen inventory.")
                }
                let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
                guard bytes.count <= 1024 * 1024 else { throw Options.usage("Deployment review exceeds the file size limit.") }
                let review = try JSONDecoder().decode(ControllerCloudDeploymentReview.self, from: bytes)
                return try encode(await cloud.applyDeployment(review))
            case .deviceStatus(let installation): return try encode(await cloud.deviceStatus(installationId: installation))
            case .publish(let local): return try encode(await cloud.publishLocalBuild(localProjectId: local))
            }
        }
        presentation.success(result, human: human(result))
    }
    private static func human(_ result: [String: Any]) -> String {
        if result["resultingSetDigest"] != nil, let bytes = try? JSONSerialization.data(withJSONObject: result),
           let review = try? JSONDecoder().decode(ControllerCloudDeploymentReview.self, from: bytes) {
            return review.summary + "\nReview this exact inventory; apply with --file ABS_REVIEW_JSON --approved."
        }
        if let status = result["status"] as? String { return "Cloud project: \(status)." }
        if let state = result["state"] as? String {
            var lines = ["Cloud: \(state)."]
            if let origin = result["activeScreenOrigin"] as? String { lines.append("Active screen origin: " + origin) }
            if let change = result["lastSuccessfulChange"] as? [String: Any] {
                if let entry = change["entryId"] as? String { lines.append("Active screen: " + entry) }
                if let date = change["changedAt"] as? String { lines.append("Last successful change: " + date) }
            }
            return lines.joined(separator: "\n")
        }
        if let items = result["items"] as? [[String: Any]] { return items.map { "\($0["id"] ?? "")  \($0["name"] ?? "")" }.joined(separator: "\n") }
        if let workspaces = result["workspaces"] as? [[String: Any]] {
            let selected = result["selectedWorkspaceId"] as? String
            return "Cloud account connected.\n" + workspaces.map { "\($0["id"] ?? "")  \($0["name"] ?? "")" + (($0["id"] as? String) == selected ? " (selected)" : "") }.joined(separator: "\n")
        }
        return "Cloud operation completed."
    }
    static func automaticallyLinksNewProject(_ method: WorkbenchAuthoringRecoveryMethod) -> Bool {
        [.projectCreate, .projectClone, .projectSourceImport].contains(method)
    }
    static func sourceKindForNewProject(_ project: WorkbenchSourceProject, descriptor: Data) throws -> String {
        let document = try JSONDecoder().decode(WorkspaceProjectDocument.self, from: descriptor)
        guard document.projectId == project.project.projectId, document.dashboardId == project.project.dashboardId,
              ["web", "react"].contains(document.kind) else { throw ControllerCloudError.invalidSource }
        return document.kind
    }
    static func linkCreatedIfConnected(_ project: WorkbenchSourceProject, client: WorkbenchBrokerClient,
                                       machineRoot: URL, environment: [String: String], kind: String? = nil) throws {
        let env = try deploymentEnvironment(environment)
        guard let text = env["SCREENPUNK_CLOUD_BASE_URL"], let base = URL(string: text),
              try ControllerCloudKeychain(server: base, clientID: "screenpunk-cli").load() != nil else { return }
        let selected = try client.workspaceStatus()
        guard let workspaceId = selected.workspaceId, let generation = selected.selectionGeneration else { throw ControllerCloudError.invalidSource }
        let descriptor = try client.sourceText(projectId: project.project.projectId, path: "screenpunk.project.json",
            expectedWorkspaceId: workspaceId, expectedSelectionGeneration: generation)
        let sourceKind = try sourceKindForNewProject(project, descriptor: Data(descriptor.text.utf8))
        try wait {
            let configuration = try await ControllerCloudConfiguration.deployment(environment: env, machineRoot: machineRoot)
            let facade = try ControllerCloudWorkbench(configuration: configuration, client: client, machineRoot: machineRoot)
            _ = try await facade.linkCreatedProjectIfConnected(localProjectId: project.project.projectId,
                name: project.project.name, kind: sourceKind)
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw ControllerCloudError.invalidResponse }
        return result
    }
    static func deploymentEnvironment(_ environment: [String: String]) throws -> [String: String] {
        if let root = WorkbenchProductionTrust.homebrewRoot() {
            _ = try WorkbenchProductionTrust.verifyPackage(root)
            let data = try Data(contentsOf: root.appendingPathComponent("Resources/Cloud/controller.json"))
            guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  config["schemaVersion"] as? Int == 1,
                  let origin = config["apiOrigin"] as? String else { throw ControllerCloudError.invalidConfiguration }
            // Installed releases trust their signed origin configuration, never ambient endpoint overrides.
            return ["SCREENPUNK_CLOUD_BASE_URL": origin]
        }
        return environment
    }
    private final class ResultBox<Value>: @unchecked Sendable {
        let lock = NSLock(); var result: Result<Value, Error>?
        func save(_ result: Result<Value, Error>) { lock.lock(); defer { lock.unlock() }; self.result = result }
        func read() -> Result<Value, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }
    static func wait<Value>(_ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
        // The CLI entrypoint is synchronous; browser opening must not use its blocked main thread.
        let done = DispatchSemaphore(value: 0), box = ResultBox<Value>()
        Task.detached { do { box.save(.success(try await operation())) } catch { box.save(.failure(error)) }; done.signal() }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let result = box.read() else { throw ControllerCloudError.invalidResponse }
        return try result.get()
    }
}
