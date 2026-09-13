import Combine
import SwiftUI
import ScreenpunkCore

/// Mac workbench: discovery, pairing, orientation, live preview, deploy, history.
public final class WorkbenchModel: ObservableObject {
    @Published public var session: WorkbenchSession
    @Published public var phone: DeviceRuntime
    @Published public var manualHost = ""
    @Published public var manualPort = ""
    @Published public var status: String?
    public let hub: LoopbackDiscovery
    /// How often the sidebar re-reads the hub so Bonjour finds show up without a click.
    public static let discoveryPollSeconds: TimeInterval = 2
    private let clock = FixedClock(Date())
#if canImport(Network) && canImport(Security)
    private var lanClients: [String: ControllerLANClient] = [:]
    private var controllerTLS: TLSIdentityMaterial?
    private var lanCodes: [String: String] = [:]
    private var browser: LANAdvertisementBrowser?
#endif

    /// `browsesLAN: false` skips the Bonjour browser so tests see only what they put in `hub`.
    public init(hub: LoopbackDiscovery = LoopbackDiscovery.shared, browsesLAN: Bool = true) {
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
        if browsesLAN {
            let browser = LANAdvertisementBrowser(hub: hub)
            browser.start()
            self.browser = browser
        }
#endif
        self.session.refreshDiscovery(hub)
    }

    public func refresh() {
        phone.advertise(on: hub)
        session.refreshDiscovery(hub)
    }

    /// Timer-driven re-read. Only writes `session` when the hub changed so the
    /// persisted snapshot is not rewritten every tick.
    public func pollDiscovery() {
        let fresh = hub.browse()
        if fresh != session.advertisements {
            session.advertisements = fresh
        }
    }

    // MARK: Sidebar

    public func visibleDevices(developer: Bool) -> [PairedDevice] {
        WorkbenchSidebar.visibleDevices(session.devices, advertisements: session.advertisements, developer: developer)
    }

    public func nearby(developer: Bool) -> [WorkbenchSidebar.NearbyEntry] {
        WorkbenchSidebar.nearby(advertisements: session.advertisements, devices: session.devices, developer: developer)
    }

    public func title(for device: PairedDevice) -> String {
        WorkbenchSidebar.title(for: device, advertisements: session.advertisements)
    }

    public func isSimulator(_ device: PairedDevice) -> Bool {
        WorkbenchSidebar.isSimulator(device, advertisements: session.advertisements)
    }

    /// The advertisement a known device can be re-paired from, if it is still on the network.
    public func repairAdvertisement(for device: PairedDevice) -> AdvertisedDevice? {
        WorkbenchSidebar.advertisement(for: device, in: session.advertisements)
    }

    public var canAddByAddress: Bool {
        WorkbenchSidebar.normalizeHost(manualHost) != nil && WorkbenchSidebar.parsePort(manualPort) != nil
    }

    /// Records the typed address and starts pairing with it in one step.
    /// Returns false, with `status` set, when the address is unusable.
    /// `pair: false` only records the entry (tests; no network).
    @discardableResult
    public func addByAddress(pair: Bool = true) -> Bool {
        guard let host = WorkbenchSidebar.normalizeHost(manualHost),
              let port = WorkbenchSidebar.parsePort(manualPort)
        else {
            status = WorkbenchCopy.invalidAddress
            return false
        }
        let advertised = hub.addManual(host: host, port: port)
        session.refreshDiscovery(hub)
        manualHost = ""
        manualPort = ""
        status = nil
        if pair {
            startPairing(advertised: advertised)
        }
        return true
    }

    public func pairAgainSelected() {
        guard let device = session.selectedDevice,
              let advertised = repairAdvertisement(for: device)
        else {
            status = TransferFailure.deviceOffline.rawValue
            return
        }
        startPairing(advertised: advertised)
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
            // Prefer the name the device sent; fall back to what it advertised.
            // The id is stored only when nothing better exists and the sidebar
            // then shows owner copy instead of it.
            let name = hello.name
                ?? advertised.name
                ?? (hello.deviceId.isEmpty ? advertised.host : hello.deviceId)
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

/// Sidebar geometry, asserted by tests. Mac guide: 14 pt body, 12 pt caption,
/// 4/8/12/16 spacing steps.
public enum WorkbenchSidebarLayout: Sendable {
    public static let rowSpacing: CGFloat = 4
    public static let rowVerticalPadding: CGFloat = 4
    public static let pairButtonMinimumHeight: CGFloat = 24
    public static let pairButtonCornerRadius: CGFloat = 8
    public static let developerViewKey = "workbench.developerView"
}

public struct WorkbenchRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject public var model: WorkbenchModel
    /// Off by default: the owner sees real devices only. On: the in-process
    /// simulator, duplicate entries, and raw `source · host:port` lines.
    @AppStorage(WorkbenchSidebarLayout.developerViewKey) private var developerView = false
    @State private var addByAddressExpanded = false
    private let discoveryTimer = Timer.publish(
        every: WorkbenchModel.discoveryPollSeconds, on: .main, in: .common
    ).autoconnect()

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
        .onReceive(discoveryTimer) { _ in
            model.pollDiscovery()
            reconcileSelection()
        }
    }

    // MARK: Sidebar

    private var selection: Binding<String?> {
        Binding(
            get: {
                let id = model.session.selectedDeviceId
                return visibleDevices.contains { $0.profile.deviceId == id } ? id : nil
            },
            set: { model.session.selectedDeviceId = $0 }
        )
    }

    private var visibleDevices: [PairedDevice] {
        model.visibleDevices(developer: developerView)
    }

    private var developerBinding: Binding<Bool> {
        Binding(
            get: { developerView },
            set: {
                developerView = $0
                reconcileSelection()
            }
        )
    }

    /// Keeps the selection on something the owner can see. A hidden simulator
    /// selected from a previous run would otherwise drive Deploy invisibly.
    private func reconcileSelection() {
        let visible = visibleDevices
        if let id = model.session.selectedDeviceId, visible.contains(where: { $0.profile.deviceId == id }) {
            return
        }
        let next = visible.first?.profile.deviceId
        if model.session.selectedDeviceId != next {
            model.session.selectedDeviceId = next
        }
    }

    private var sidebar: some View {
        let devices = visibleDevices
        let nearby = model.nearby(developer: developerView)
        return List(selection: selection) {
            Section {
                if devices.isEmpty {
                    hint(WorkbenchCopy.noDevices)
                }
                ForEach(devices) { device in
                    deviceRow(device)
                        .tag(Optional(device.profile.deviceId))
                }
            } header: {
                Text(WorkbenchCopy.devicesSection)
            }

            Section {
                if nearby.isEmpty {
                    hint(WorkbenchCopy.noNearby)
                }
                // Index ids keep these rows out of the device selection.
                ForEach(nearby.indices, id: \.self) { index in
                    nearbyRow(nearby[index])
                }
                DisclosureGroup(isExpanded: $addByAddressExpanded) {
                    addByAddressForm
                } label: {
                    Text(WorkbenchCopy.addByAddress)
                        .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
                }
            } header: {
                HStack {
                    Text(WorkbenchCopy.addDeviceSection)
                    Spacer()
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(WorkbenchCopy.refresh)
                    .accessibilityLabel(WorkbenchCopy.refresh)
                }
            }

            Section {
                DisclosureGroup {
                    Toggle(WorkbenchCopy.developerToggle, isOn: developerBinding)
                        .font(.callout)
                } label: {
                    Text(WorkbenchCopy.developerSection)
                        .font(.callout)
                        .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Screenpunk")
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, WorkbenchSidebarLayout.rowVerticalPadding)
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSidebarLayout.rowSpacing) {
            Text(model.title(for: device))
                .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
            Text(WorkbenchSidebar.subtitle(for: device))
                .font(.caption)
                .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
        }
        .padding(.vertical, WorkbenchSidebarLayout.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private func nearbyRow(_ entry: WorkbenchSidebar.NearbyEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: WorkbenchSidebarLayout.rowSpacing) {
                Text(entry.title)
                    .foregroundStyle(GuideColor.text(colorScheme: colorScheme))
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(WorkbenchCopy.pair) {
                model.startPairing(advertised: entry.advertisement)
            }
            .buttonStyle(SidebarActionButtonStyle(
                fill: GuideColor.action(colorScheme: colorScheme),
                label: GuideColor.onAction(colorScheme: colorScheme)
            ))
            .accessibilityLabel("\(WorkbenchCopy.pair) \(entry.title)")
        }
        .padding(.vertical, WorkbenchSidebarLayout.rowVerticalPadding)
    }

    private var addByAddressForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(WorkbenchCopy.hostPlaceholder, text: $model.manualHost)
                    .textFieldStyle(.roundedBorder)
                TextField(WorkbenchCopy.portPlaceholder, text: $model.manualPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                Button(WorkbenchCopy.pair) {
                    _ = model.addByAddress()
                }
                .buttonStyle(SidebarActionButtonStyle(
                    fill: GuideColor.action(colorScheme: colorScheme),
                    label: GuideColor.onAction(colorScheme: colorScheme)
                ))
                .disabled(model.canAddByAddress == false)
                .opacity(model.canAddByAddress ? 1 : 0.5)
                .accessibilityLabel("\(WorkbenchCopy.pair) \(WorkbenchCopy.addByAddress)")
            }
            Text(WorkbenchCopy.invalidAddress)
                .font(.caption)
                .foregroundStyle(GuideColor.secondary(colorScheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, WorkbenchSidebarLayout.rowVerticalPadding)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let device = model.session.selectedDevice,
               visibleDevices.contains(where: { $0.profile.deviceId == device.profile.deviceId })
            {
                // Code card + 520 pt preview + actions exceed the minimum window
                // height; without a scroll view the Deploy row is clipped away.
                ScrollView {
                    deviceDetail(device)
                }
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
                Text(model.title(for: device))
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

            // Only this device's code. Falling back to the loopback runtime showed
            // its fixed code as a "new code" right after a real pairing succeeded.
            if let code = device.pairingCode {
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
                // Known devices leave the Add Device list; this is how a device
                // that was unlinked on the phone gets a fresh code.
                if device.pairingCode == nil, model.repairAdvertisement(for: device) != nil {
                    Button(WorkbenchCopy.pairAgain) { model.pairAgainSelected() }
                }
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
}

/// Compact brand-action pill for sidebar rows. The label carries the fill and
/// the content shape so the whole pill is the click target.
struct SidebarActionButtonStyle: ButtonStyle {
    var fill: Color
    var label: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: WorkbenchSidebarLayout.pairButtonCornerRadius, style: .continuous
        )
        return configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: WorkbenchSidebarLayout.pairButtonMinimumHeight)
            .foregroundStyle(label)
            .background(fill, in: shape)
            .overlay {
                shape.fill(Color.black.opacity(configuration.isPressed ? 0.22 : 0))
            }
            .contentShape(shape)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
