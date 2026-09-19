import Foundation
import Combine
import ScreenpunkCore
#if os(iOS)
import UIKit

@MainActor
private final class UIKitBrightnessDisplay: DeviceBrightnessDisplay {
    let screen: UIScreen
    init(screen: UIScreen) { self.screen = screen }
    var brightness: Double {
        get { Double(screen.brightness) }
        set { screen.brightness = CGFloat(newValue) }
    }
}
#endif

/// Foreground-only adapter. Settings persist separately on the device; this
/// object applies them without a Mac connection and relinquishes on suspension.
@MainActor
public final class DeviceBrightnessController: NSObject, ObservableObject {
    /// SensorKit ambient samples require an Apple-approved research entitlement;
    /// Screenpunk has no general-purpose raw ambient-light access.
    public static let supportsAmbientLightSensor = false
    @Published public private(set) var isApplied = false
    private var settings = DeviceBrightnessSettings()
    private var enabled = false
    private var timer: Timer?
#if os(iOS)
    private var session: DeviceBrightnessSession?
#endif

    public override init() {
        super.init()
#if os(iOS)
        // Brightness is supported on the integrated main screen only.
        session = DeviceBrightnessSession(display: UIKitBrightnessDisplay(screen: UIScreen.main))
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification, UIApplication.significantTimeChangeNotification,
                     NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSCalendarDayChanged] {
            center.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(brightnessChanged),
                           name: UIScreen.brightnessDidChangeNotification, object: UIScreen.main)
#endif
    }

    /// The caller gates this with both scene activity and pairing state.
    @discardableResult public func setActive(_ active: Bool) -> Bool {
        enabled = active
        refresh()
        return isApplied
    }

    @discardableResult public func update(settings: DeviceBrightnessSettings) -> Bool {
        self.settings = settings
        refresh()
        return isApplied
    }

    /// Call when unlinking or removing the device runtime view. May be reused.
    public func stop() { setActive(false) }

    private func refresh(forceInactive: Bool = false) {
        timer?.invalidate()
        timer = nil
#if os(iOS)
        guard let session else { reportApplied(false); return }
        let active = enabled && !forceInactive && UIApplication.shared.applicationState == .active
        // Deactivate first to avoid applying a just-edited setting in background.
        if !active { session.setActive(false, at: Date()) }
        session.update(settings: settings, at: Date())
        if active && !session.isActive { session.setActive(true, at: Date()) }
        reportApplied(session.isApplied)
        guard active, settings.mode == .schedule else { return }
        let next = DeviceBrightnessSchedule.nextEvaluation(after: Date())
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
#else
        reportApplied(enabled && settings.mode == .system)
#endif
    }

    private func reportApplied(_ value: Bool) {
        if isApplied != value { isApplied = value }
    }

#if os(iOS)
    @objc private func environmentChanged(_ notification: Notification) {
        let inactive = notification.name == UIApplication.willResignActiveNotification
            || notification.name == UIApplication.didEnterBackgroundNotification
        refresh(forceInactive: inactive)
    }

    @objc private func brightnessChanged() {
        session?.displayBrightnessDidChange(at: Date())
        reportApplied(session?.isApplied ?? false)
    }
#endif

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
