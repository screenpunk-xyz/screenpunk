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
    }

    public func confirmPairing() {
        guard let id = session.selectedDeviceId else { return }
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
        session.forgetUnreachable(deviceId: id)
        status = session.lastForgetMessage
    }
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
