import Foundation
import ScreenpunkController

/// One interactive GUI Apply uses one trusted local-review socket. The
/// production verifier must register this Mac binary on this same connection;
/// otherwise no plan can be submitted with GUI consent provenance.
final class MacBrokerApplySession: @unchecked Sendable {
    let client: WorkbenchBrokerClient
    let selected: WorkbenchWorkspaceStatus
    let adapter: MacBrokerDeploymentAdapter
    private var renewal: Task<Void, Never>?

    private init(client: WorkbenchBrokerClient, selected: WorkbenchWorkspaceStatus,
                 adapter: MacBrokerDeploymentAdapter) {
        self.client = client; self.selected = selected; self.adapter = adapter
    }

    static func open(environment: WorkbenchBrokerEnvironment,
                     expectedControllerHome: String) throws -> MacBrokerApplySession {
        let client = WorkbenchBrokerClient(environment: environment,
                                           credentialScope: .localReview)
        do {
            try client.connect()
            guard try client.hello().controllerHomePath == expectedControllerHome else {
                throw MacBrokerDeploymentAdapter.Error.staleSelection
            }
            // Registration verifies the connected Mac process; ordinary token
            // access or a claimed GUI role cannot substitute for this step.
            _ = try client.registerGUIConsumer()
            let selected = try client.workspaceStatus()
            let adapter = try MacBrokerDeploymentAdapter(client: client, selected: selected)
            let session = MacBrokerApplySession(client: client, selected: selected,
                                                adapter: adapter)
            session.startRenewing()
            return session
        } catch {
            _ = try? client.releaseGUIConsumer()
            client.close()
            throw error
        }
    }

    private func startRenewing() {
        renewal = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { break }
                // An expired or rejected renewal leaves Apply unavailable:
                // the adapter renews again immediately before submission.
                guard (try? self.client.renewGUIConsumer()) != nil else { break }
            }
        }
    }

    func close() async {
        renewal?.cancel()
        await renewal?.value
        renewal = nil
        _ = try? client.releaseGUIConsumer()
        client.close()
    }
}
