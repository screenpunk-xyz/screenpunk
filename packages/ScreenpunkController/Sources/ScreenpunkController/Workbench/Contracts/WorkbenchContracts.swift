import Foundation

public enum WorkbenchIPCErrorCode: String, Codable, Sendable {
    case invalidConfiguration, insecureRuntime, alreadyRunning, unavailable, unauthorizedPeer
    case authenticationFailed, instanceMismatch, unsupportedVersion, invalidRequest, methodNotFound
    case frameTooLarge, resourceLimit, timedOut, disconnected
    case workspaceExists, workspaceConflict, workspaceIncomplete, invalidWorkspacePath
    case migrationRequired
    case incompatibleOwner
    case confirmationRequired
    case credentialCleanupRequired
    case connectionValidationFailed
    case serviceBusy
    case remoteOutcomeUnknown
    case publicationOutcomeUnknown
    case toolchainTrustUnavailable
}

public struct WorkbenchIPCError: Error, LocalizedError, Codable, Sendable, Equatable {
    public let code: WorkbenchIPCErrorCode
    public var message: String {
        switch code {
        case .invalidConfiguration: return "Invalid explicit broker runtime configuration."
        case .insecureRuntime: return "Broker runtime ownership, permissions or file identity is unsafe."
        case .alreadyRunning: return "A broker already holds this runtime lock."
        case .unavailable: return "Broker runtime or socket is unavailable."
        case .unauthorizedPeer: return "Broker peer UID does not match the configured owner."
        case .authenticationFailed: return "Broker authentication failed."
        case .instanceMismatch: return "Broker instance changed; reconnect using its current locator."
        case .unsupportedVersion: return "Broker API version is unsupported."
        case .invalidRequest: return "Broker request is malformed or contains unsupported fields."
        case .methodNotFound: return "Broker method is not supported."
        case .frameTooLarge: return "Broker frame exceeds its configured limit."
        case .resourceLimit: return "Broker resource limit reached."
        case .timedOut: return "Broker IPC deadline expired."
        case .disconnected: return "Broker connection closed."
        case .workspaceExists: return "Workspace destination already exists."
        case .workspaceConflict: return "Workspace identity or generation changed."
        case .workspaceIncomplete: return "Workspace recovery material or required content needs review."
        case .invalidWorkspacePath: return "Workspace path is invalid or unsafe."
        case .migrationRequired: return "Legacy source or package data requires an explicit migration plan before a new workspace is selected."
        case .incompatibleOwner: return "An incompatible Screenpunk GUI or legacy MCP writer is running; close it before changing shared local state."
        case .confirmationRequired: return "A trusted service-side local confirmation channel is required before connection approval."
        case .credentialCleanupRequired: return "The connection intent is inactive, but its scoped credential still needs local cleanup. Retry inspection or denial when Keychain is available."
        case .connectionValidationFailed: return "Home Assistant validation or setup failed; inspect the setup status before retrying."
        case .serviceBusy: return "The service cannot complete this lifecycle operation while work, GUI consumers, or another lifecycle reservation are active. Inspect service status before retrying."
        case .remoteOutcomeUnknown: return "The device may have accepted the connection; inspect the intent and device state before retrying."
        case .publicationOutcomeUnknown: return "A mutation may have been published, but its response or durability could not be confirmed. Inspect current state before retrying."
        case .toolchainTrustUnavailable: return "No authenticated installed kit matches this request under the production release trust policy."
        }
    }
    public var errorDescription: String? { message }
    public init(_ code: WorkbenchIPCErrorCode) { self.code = code }
    private enum CodingKeys: String, CodingKey { case code, message }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(WorkbenchIPCErrorCode.self, forKey: .code)
        // Peer text is not an error message authority.
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code); try c.encode(message, forKey: .message)
    }
}

public struct WorkbenchBrokerSnapshot: Codable, Sendable, Equatable {
    public let apiVersion: String
    public let instanceId: String
    public let status: String
    public let supportedMethods: [String]
    public let workspaceState: String
    public let build: String
    public let devices: String
    public let screenshots: String
    public let controllerHomePath: String?
    init(instanceId: String, supportedMethods: [String] = WorkbenchMethodRegistry.supportedMethods,
         workspaceState: String = "unconfigured", devices: String = "unavailable", controllerHomePath: String? = nil) {
        apiVersion = "1.0"; self.instanceId = instanceId; status = "ready"
        self.supportedMethods = supportedMethods
        self.workspaceState = workspaceState; build = "unavailable"; self.devices = devices; screenshots = "unavailable"
        self.controllerHomePath = controllerHomePath
    }
}

public enum WorkbenchMethodRegistry {
    public static let supportedMethods = ["system.hello", "system.capabilities", "system.health",
                                          "service.lifecycle", "service.drain"]
    static func validate(method: String, params: [String: Any]) throws {
        guard supportedMethods.contains(method) else { throw WorkbenchIPCError(.methodNotFound) }
        guard params.isEmpty else { throw WorkbenchIPCError(.invalidRequest) }
    }
}

enum WorkbenchRPCResult: Codable {
    case snapshot(WorkbenchBrokerSnapshot)
    case read(WorkbenchReadResult)
    case deviceAction(WorkbenchDeviceActionResult)
    case connectionAction(WorkbenchConnectionActionResult)
    case lifecycle(WorkbenchServiceLifecycleResult)
    case authoringAction(WorkbenchAuthoringRecoveryResult)
    case sourceText(WorkbenchSourceTextRead)
    case sourceChunk(WorkbenchSourceChunkRead)
    case packageImport(WorkbenchPackageImportResult)
    case deploymentAction(WorkbenchDeploymentActionResult)
    case connectionReview(WorkbenchConnectionReview)
    case homeAssistantReview(WorkbenchHomeAssistantReview)
    case homeAssistantAttempt(WorkbenchHomeAssistantAttemptView)
    case workspaceOperation(WorkbenchWorkspaceOperationStatus)
    case workspaceOperationList(WorkbenchWorkspaceOperationList)
    case operationInventory(WorkbenchOperationInventory)
    case operationEntry(WorkbenchOperationEntry)
    case retainedDeploymentEvidence(WorkbenchRetainedDeploymentEvidenceRead)
    case deviceLog(WorkbenchDeviceLogRead)
    case screenMutation(WorkbenchScreenMutationResult)
    case nativeDoctor(WorkbenchNativeDoctorRead)
    case toolchainRequirements(WorkbenchToolchainRequirementsRead)
    case toolchainInstall(WorkbenchToolchainInstallResult)
    case workspacePackage(WorkbenchWorkspacePackageResult)
    case guiConsumer(WorkbenchGUIConsumerResult)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let snapshot = try? value.decode(WorkbenchBrokerSnapshot.self) { self = .snapshot(snapshot) }
        else if let read = try? value.decode(WorkbenchReadResult.self) { self = .read(read) }
        else if let authoring = try? value.decode(WorkbenchAuthoringRecoveryResult.self) {
            self = .authoringAction(authoring)
        }
        else if let sourceChunk = try? value.decode(WorkbenchSourceChunkRead.self) {
            self = .sourceChunk(sourceChunk)
        }
        else if let sourceText = try? value.decode(WorkbenchSourceTextRead.self) {
            self = .sourceText(sourceText)
        }
        else if let imported = try? value.decode(WorkbenchPackageImportResult.self),
                WorkbenchPackageImportMethod(rawValue: imported.kind) != nil {
            self = .packageImport(imported)
        }
        else if let deployment = try? value.decode(WorkbenchDeploymentActionResult.self),
                WorkbenchDeploymentMethod(rawValue: deployment.kind) != nil {
            self = .deploymentAction(deployment)
        }
        else if let review = try? value.decode(WorkbenchConnectionReview.self) {
            self = .connectionReview(review)
        } else if let review = try? value.decode(WorkbenchHomeAssistantReview.self) {
            self = .homeAssistantReview(review)
        } else if let attempt = try? value.decode(WorkbenchHomeAssistantAttemptView.self) {
            self = .homeAssistantAttempt(attempt)
        } else if let operation = try? value.decode(WorkbenchWorkspaceOperationStatus.self) {
            self = .workspaceOperation(operation)
        } else if let operations = try? value.decode(WorkbenchWorkspaceOperationList.self) {
            self = .workspaceOperationList(operations)
        } else if let inventory = try? value.decode(WorkbenchOperationInventory.self) {
            self = .operationInventory(inventory)
        } else if let entry = try? value.decode(WorkbenchOperationEntry.self) {
            self = .operationEntry(entry)
        } else if let retained = try? value.decode(WorkbenchRetainedDeploymentEvidenceRead.self) {
            self = .retainedDeploymentEvidence(retained)
        } else if let log = try? value.decode(WorkbenchDeviceLogRead.self) {
            self = .deviceLog(log)
        } else if let screen = try? value.decode(WorkbenchScreenMutationResult.self) {
            self = .screenMutation(screen)
        } else if let doctor = try? value.decode(WorkbenchNativeDoctorRead.self) {
            self = .nativeDoctor(doctor)
        } else if let requirements = try? value.decode(WorkbenchToolchainRequirementsRead.self) {
            self = .toolchainRequirements(requirements)
        } else if let installation = try? value.decode(WorkbenchToolchainInstallResult.self) {
            self = .toolchainInstall(installation)
        } else if let package = try? value.decode(WorkbenchWorkspacePackageResult.self),
                  WorkbenchWorkspacePackageMethod(rawValue: package.kind) != nil {
            self = .workspacePackage(package)
        } else if let gui = try? value.decode(WorkbenchGUIConsumerResult.self) {
            self = .guiConsumer(gui)
        }
        else if let action = try? value.decode(WorkbenchDeviceActionResult.self),
                ["discovered", "endpoint", "pairing", "pending", "device", "removed", "settings", "connections", "screenSet"].contains(action.kind) {
            self = .deviceAction(action)
        } else if let lifecycle = try? value.decode(WorkbenchServiceLifecycleResult.self) {
            self = .lifecycle(lifecycle)
        } else { self = .connectionAction(try value.decode(WorkbenchConnectionActionResult.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .snapshot(let snapshot): try value.encode(snapshot)
        case .read(let result): try value.encode(result)
        case .deviceAction(let result): try value.encode(result)
        case .connectionAction(let result): try value.encode(result)
        case .lifecycle(let result): try value.encode(result)
        case .authoringAction(let result): try value.encode(result)
        case .sourceText(let result): try value.encode(result)
        case .sourceChunk(let result): try value.encode(result)
        case .packageImport(let result): try value.encode(result)
        case .deploymentAction(let result): try value.encode(result)
        case .connectionReview(let result): try value.encode(result)
        case .homeAssistantReview(let result): try value.encode(result)
        case .homeAssistantAttempt(let result): try value.encode(result)
        case .workspaceOperation(let result): try value.encode(result)
        case .workspaceOperationList(let result): try value.encode(result)
        case .operationInventory(let result): try value.encode(result)
        case .operationEntry(let result): try value.encode(result)
        case .retainedDeploymentEvidence(let result): try value.encode(result)
        case .deviceLog(let result): try value.encode(result)
        case .screenMutation(let result): try value.encode(result)
        case .nativeDoctor(let result): try value.encode(result)
        case .toolchainRequirements(let result): try value.encode(result)
        case .toolchainInstall(let result): try value.encode(result)
        case .workspacePackage(let result): try value.encode(result)
        case .guiConsumer(let result): try value.encode(result)
        }
    }
}

struct WorkbenchWireResponse: Codable {
    let apiVersion: String
    let requestId: String
    let ok: Bool
    let result: WorkbenchRPCResult?
    let error: WorkbenchIPCError?
    init(requestId: String, result: WorkbenchBrokerSnapshot) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; self.result = .snapshot(result); error = nil
    }
    init(requestId: String, read: WorkbenchReadResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .read(read); error = nil
    }
    init(requestId: String, deviceAction: WorkbenchDeviceActionResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .deviceAction(deviceAction); error = nil
    }
    init(requestId: String, connectionAction: WorkbenchConnectionActionResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .connectionAction(connectionAction); error = nil
    }
    init(requestId: String, lifecycle: WorkbenchServiceLifecycleResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .lifecycle(lifecycle); error = nil
    }
    init(requestId: String, authoringAction: WorkbenchAuthoringRecoveryResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .authoringAction(authoringAction); error = nil
    }
    init(requestId: String, sourceText: WorkbenchSourceTextRead) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .sourceText(sourceText); error = nil
    }
    init(requestId: String, sourceChunk: WorkbenchSourceChunkRead) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .sourceChunk(sourceChunk); error = nil
    }
    init(requestId: String, packageImport: WorkbenchPackageImportResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .packageImport(packageImport); error = nil
    }
    init(requestId: String, deploymentAction: WorkbenchDeploymentActionResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .deploymentAction(deploymentAction); error = nil
    }
    init(requestId: String, connectionReview: WorkbenchConnectionReview) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .connectionReview(connectionReview); error = nil
    }
    init(requestId: String, homeAssistantReview: WorkbenchHomeAssistantReview) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .homeAssistantReview(homeAssistantReview); error = nil
    }
    init(requestId: String, homeAssistantAttempt: WorkbenchHomeAssistantAttemptView) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .homeAssistantAttempt(homeAssistantAttempt); error = nil
    }
    init(requestId: String, workspaceOperation: WorkbenchWorkspaceOperationStatus) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .workspaceOperation(workspaceOperation); error = nil
    }
    init(requestId: String, workspaceOperationList: WorkbenchWorkspaceOperationList) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .workspaceOperationList(workspaceOperationList); error = nil
    }
    init(requestId: String, operationInventory: WorkbenchOperationInventory) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .operationInventory(operationInventory); error = nil
    }
    init(requestId: String, operationEntry: WorkbenchOperationEntry) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .operationEntry(operationEntry); error = nil
    }
    init(requestId: String, retainedDeploymentEvidence: WorkbenchRetainedDeploymentEvidenceRead) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .retainedDeploymentEvidence(retainedDeploymentEvidence); error = nil
    }
    init(requestId: String, deviceLog: WorkbenchDeviceLogRead) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .deviceLog(deviceLog); error = nil
    }
    init(requestId: String, screenMutation: WorkbenchScreenMutationResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .screenMutation(screenMutation); error = nil
    }
    init(requestId: String, nativeDoctor: WorkbenchNativeDoctorRead) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .nativeDoctor(nativeDoctor); error = nil
    }
    init(requestId: String, toolchainRequirements: WorkbenchToolchainRequirementsRead) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .toolchainRequirements(toolchainRequirements); error = nil
    }
    init(requestId: String, toolchainInstall: WorkbenchToolchainInstallResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true
        result = .toolchainInstall(toolchainInstall); error = nil
    }
    init(requestId: String, workspacePackage: WorkbenchWorkspacePackageResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .workspacePackage(workspacePackage); error = nil
    }
    init(requestId: String, guiConsumer: WorkbenchGUIConsumerResult) {
        apiVersion = "1.0"; self.requestId = requestId; ok = true; result = .guiConsumer(guiConsumer); error = nil
    }
    init(requestId: String, error: WorkbenchIPCError) {
        apiVersion = "1.0"; self.requestId = requestId; ok = false; result = nil; self.error = error
    }
}
