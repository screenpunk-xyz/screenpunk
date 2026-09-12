import SwiftUI
import ScreenpunkCore

/// Mac workbench: discovery, pairing, orientation, live preview, deploy, history.
public final class WorkbenchModel: ObservableObject {
    @Published public var session: WorkbenchSession
    @Published public var phone: DeviceRuntime
    @Published public var manualHost = "127.0.0.1"
    @Published public var manualPort = "7843"
    @Published public var status: String?
    public let hub: LoopbackDiscovery
    private let clock = FixedClock(Date())
#if canImport(Network) && canImport(Security)
    private var lanClients: [String: ControllerLANClient] = [:]
    private var controllerTLS: TLSIdentityMaterial?
    private var lanCodes: [String: String] = [:]
    private var browser: LANAdvertisementBrowser?
#endif

    public init(hub: LoopbackDiscovery = LoopbackDiscovery.shared) {
        self.hub = hub
        let controller = PairingIdentityFactory.make(
            role: .controller,
            bytes: [UInt8](repeating: 0x02, count: 32)
        )
        var session = WorkbenchSession(controllerIdentity: controller)
        session.importDraft(StoredRevision.offlineFixture)
        self.session = session

        let identity = PairingIdentityFactory.make(
            role: .device,
            bytes: [UInt8](repeating: 0x01, count: 32)
        )
        let profile = DeviceProfile(deviceId: "phone-1", name: "Loopback iPhone")
        let ad = AdvertisedDevice(
            deviceId: "phone-1",
            host: "127.0.0.1",
            port: 7843,
            source: .loopback
        )
        var phone = DeviceRuntime(identity: identity, profile: profile, advertisement: ad)
        phone.advertise(on: hub)
        self.phone = phone
#if canImport(Network) && canImport(Security)
        let browser = LANAdvertisementBrowser(hub: hub)
        browser.start()
        self.browser = browser
#endif
        self.session.refreshDiscovery(hub)
    }

    public func refresh() {
        phone.advertise(on: hub)
        session.refreshDiscovery(hub)
    }

    public func addManual() {
        let port = Int(manualPort) ?? 7843
        session.addManual(host: manualHost, port: port, hub: hub)
    }

    public func startPairing(advertised: AdvertisedDevice) {
        if advertised.source == .loopback {
            do {
                try session.beginPairing(
                    advertised: advertised,
                    phone: &phone,
                    expectedCode: "833492",
                    clock: clock,
                    nonce: [UInt8](repeating: 0x03, count: 16)
                )
                status = nil
            } catch {
                status = String(describing: error)
            }
            return
        }
#if canImport(Network) && canImport(Security)
        startLANPairing(advertised: advertised)
#else
        status = TransferFailure.deviceOffline.rawValue
#endif
    }

    public func confirmPairing() {
        guard let id = session.selectedDeviceId else { return }
#if canImport(Network) && canImport(Security)
        if let client = lanClients[id], let code = lanCodes[id] {
            do {
                try client.confirmPairing(code: code)
                session.markPaired(deviceId: id)
                status = nil
            } catch {
                status = String(describing: error)
            }
            return
        }
#endif
        do {
            try session.confirmPairing(
                deviceId: id,
                code: "833492",
                phone: &phone,
                clock: clock
            )
            status = nil
        } catch {
            status = String(describing: error)
        }
    }

    public func setOrientation(_ orientation: DeviceOrientation) {
        guard let id = session.selectedDeviceId else { return }
        session.setOrientation(orientation, deviceId: id)
    }

    public func deploy() {
        guard let id = session.selectedDeviceId, let draft = session.selectedDraft else { return }
#if canImport(Network) && canImport(Security)
        if let client = lanClients[id] {
            deployOverLAN(client: client, deviceId: id, revision: draft, deploymentId: UUID().uuidString)
            return
        }
#endif
        do {
            let record = try session.deploy(
                deploymentId: UUID().uuidString,
                revision: draft,
                deviceId: id,
                phone: &phone
            )
            status = record.phase.rawValue
        } catch {
            status = String(describing: error)
        }
    }

    public func rollback(_ revision: StoredRevision) {
        guard let id = session.selectedDeviceId else { return }
#if canImport(Network) && canImport(Security)
        if let client = lanClients[id] {
            deployOverLAN(client: client, deviceId: id, revision: revision, deploymentId: UUID().uuidString)
            return
        }
#endif
        do {
            let record = try session.rollback(
                to: revision,
                deviceId: id,
                phone: &phone,
                deploymentId: UUID().uuidString
            )
            status = record.phase.rawValue
        } catch {
            status = String(describing: error)
        }
    }

    public func forgetSelected() {
        guard let id = session.selectedDeviceId else { return }
#if canImport(Network) && canImport(Security)
        lanClients[id]?.cancel()
        lanClients.removeValue(forKey: id)
        lanCodes.removeValue(forKey: id)
#endif
        session.forgetUnreachable(deviceId: id)
        status = session.lastForgetMessage
    }

#if canImport(Network) && canImport(Security)
    private func controllerIdentity() throws -> TLSIdentityMaterial {
        if let controllerTLS { return controllerTLS }
        let made = try TLSIdentity.loadOrCreate(role: .controller)
        controllerTLS = made
        session.controllerIdentity = made.pairingIdentity
        return made
    }

    private func startLANPairing(advertised: AdvertisedDevice) {
        do {
            guard let port = UInt16(exactly: advertised.port), port > 0 else {
                throw TransferFailure.deviceOffline
            }
            let identity = try controllerIdentity()
            let client = ControllerLANClient(identity: identity)
            try client.connect(host: advertised.host, port: port)
            let hello = try client.hello()
            let begin = try client.beginPairing(nonce: PairingIdentityFactory.nonce())
            lanClients[advertised.deviceId] = client
            lanCodes[advertised.deviceId] = begin.code
            let name = hello.deviceId.isEmpty ? advertised.host : hello.deviceId
            session.recordPairedDevice(
                profile: DeviceProfile(deviceId: advertised.deviceId, name: name),
                pairingCode: begin.code
            )
            status = nil
        } catch {
            status = String(describing: error)
        }
    }

    private func deployOverLAN(
        client: ControllerLANClient,
        deviceId: String,
        revision: StoredRevision,
        deploymentId: String
    ) {
        do {
            let queued = DeploymentRecord(
                deploymentId: deploymentId,
                revision: revision.revision,
                dashboardId: revision.dashboardId,
                deviceId: deviceId,
                phase: .queued
            )
            let body = LANDeployBody(
                deployment: queued,
                revision: revision,
                files: try LANPackageFiles.offlineFixture()
            )
            let outcome = try client.deploy(body)
            session.applyRemoteDeployment(outcome, revision: revision, deviceId: deviceId)
            status = outcome.phase.rawValue
        } catch {
            status = String(describing: error)
        }
    }
#endif
}

public struct WorkbenchRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject public var model: WorkbenchModel

    public init(model: WorkbenchModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .background(GuideColor.canvas(colorScheme: colorScheme))
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.session.selectedDeviceId },
            set: { model.session.selectedDeviceId = $0 }
        )) {
            Section("Devices") {
                ForEach(model.session.devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.profile.name)
                            .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
                        Text(deviceSubtitle(device))
                            .font(.caption)
                            .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
                    }
                    .tag(Optional(device.profile.deviceId))
                }
            }
            Section("Add Device") {
                ForEach(model.session.advertisements) { ad in
                    Button("\(ad.source.rawValue) \(ad.host):\(ad.port)") {
                        model.startPairing(advertised: ad)
                    }
                }
                HStack {
                    TextField("Host", text: $model.manualHost)
                    TextField("Port", text: $model.manualPort)
                    Button("Add") { model.addManual() }
                }
                Button("Refresh") { model.refresh() }
            }
        }
        .navigationTitle("Screenpunk")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let device = model.session.selectedDevice {
                deviceDetail(device)
            } else {
                Text("Select or add a device.")
                    .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GuideColor.canvas(colorScheme: colorScheme))
    }

    @ViewBuilder
    private func deviceDetail(_ device: PairedDevice) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(device.profile.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
                Spacer()
                Picker("Orientation", selection: Binding(
                    get: { device.profile.orientation },
                    set: { model.setOrientation($0) }
                )) {
                    Text("Portrait").tag(DeviceOrientation.portrait)
                    Text("Landscape").tag(DeviceOrientation.landscape)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if let code = device.pairingCode ?? model.phone.pairingCode {
                PairingCodeView(code: code, onConfirm: model.confirmPairing)
                    .padding(.horizontal, 20)
            }

            Text(model.session.livePreviewLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
                .padding(.horizontal, 20)
                .accessibilityLabel(WorkbenchCopy.livePreview)

            preview
                .frame(
                    width: CGFloat(device.profile.width),
                    height: CGFloat(min(device.profile.height, 520))
                )
                .frame(maxWidth: .infinity)

            HStack {
                Button("Deploy") { model.deploy() }
                    .disabled(device.pairingCode != nil)
                Button("Forget") { model.forgetSelected() }
                if let status = model.status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
                }
            }
            .padding(.horizontal, 20)

            if device.history.isEmpty == false {
                Text("History")
                    .font(.headline)
                    .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
                    .padding(.horizontal, 20)
                ForEach(device.history) { revision in
                    HStack {
                        Text("\(revision.name) · \(revision.revision.prefix(8))")
                            .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
                        Spacer()
                        Button("Rollback") { model.rollback(revision) }
                    }
                    .padding(.horizontal, 20)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if model.session.selectedDraft?.revision == StoredRevision.offlineFixture.revision,
           let store = try? PackageAssetStore.bundledOfflineFixture()
        {
            DashboardRuntimeView(store: store, onUnlink: {})
        } else {
            Text("No draft selected")
                .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
        }
    }

    private func deviceSubtitle(_ device: PairedDevice) -> String {
        let reach = device.reachable ? "reachable" : "unreachable"
        let dash = device.activeRevision == nil ? "No dashboard" : StoredRevision.offlineFixture.name
        return "\(reach) · \(device.profile.orientation.rawValue) · \(dash)"
    }
}
