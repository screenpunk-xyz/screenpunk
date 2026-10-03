import Foundation
#if os(macOS)

/// Private machine-local journal for dedicated Home Assistant setup. Its
/// records contain scope and Keychain references, never credential values.
public final class WorkbenchHomeAssistantAttemptFileStore: WorkbenchHomeAssistantAttemptStore {
    private struct State: Codable {
        var schemaVersion = 1
        var attempts: [String: WorkbenchHomeAssistantAttempt] = [:]
    }

    private let root: WorkspaceFiles
    private let member = "home-assistant-attempts.json"
    private let maximumBytes = 512 * 1024

    public init(path: String) throws {
        do { root = try WorkspaceFiles(path: path, create: true) }
        catch WorkspaceError.alreadyExists { root = try WorkspaceFiles(path: path) }
    }

    public func load(intentId: String) throws -> WorkbenchHomeAssistantAttempt? {
        try root.locked { try read().attempts[intentId] }
    }

    public func begin(_ attempt: WorkbenchHomeAssistantAttempt) throws {
        try update { state in
            guard state.attempts[attempt.intentId] == nil else {
                throw WorkbenchHomeAssistantSetupFailure.conflict
            }
            state.attempts[attempt.intentId] = attempt
        }
    }

    public func transition(from: WorkbenchHomeAssistantAttempt,
                           to: WorkbenchHomeAssistantAttempt) throws {
        try update { state in
            guard from.intentId == to.intentId,
                  state.attempts[from.intentId] == from else {
                throw WorkbenchHomeAssistantSetupFailure.conflict
            }
            state.attempts[from.intentId] = to
        }
    }

    private func update(_ body: (inout State) throws -> Void) throws {
        try root.locked {
            var state = try read()
            try body(&state)
            guard state.attempts.count <= 512 else {
                throw WorkbenchHomeAssistantSetupFailure.conflict
            }
            let data = try JSONEncoder().encode(state)
            guard data.count <= maximumBytes else {
                throw WorkbenchHomeAssistantSetupFailure.conflict
            }
            let expected = try root.exists(root.fd, member)
                ? WorkspaceNodeID(root.metadata(root.fd, member)) : nil
            try root.write(root.fd, member, data: data, expected: expected)
        }
    }

    private func read() throws -> State {
        guard try root.exists(root.fd, member) else { return State() }
        let data = try root.read(root.fd, member, maxBytes: maximumBytes)
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.schemaVersion == 1, state.attempts.count <= 512,
              state.attempts.allSatisfy({ $0.key == $0.value.intentId }) else {
            throw WorkbenchHomeAssistantSetupFailure.conflict
        }
        return state
    }
}
#endif
