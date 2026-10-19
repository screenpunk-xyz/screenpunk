import Foundation
import MapKit
import WebKit
import ScreenpunkCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct NativeMapBounds {
    let frame: CGRect
    let viewportWidth: Double
    let radius: Double
    let visible: Bool
    init(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              let rect = try? JSONDecoder().decode([String: Double].self, from: data),
              Set(rect.keys) == Set(["x", "y", "width", "height", "viewportWidth", "radius", "visible"]),
              rect.values.allSatisfy({ $0.isFinite && abs($0) <= 10000 }),
              let x = rect["x"], let y = rect["y"], let w = rect["width"], let h = rect["height"],
              let viewport = rect["viewportWidth"], viewport > 0,
              let radius = rect["radius"], (0...64).contains(radius),
              let visible = rect["visible"], visible == 0 || visible == 1,
              (0...2048).contains(w), (0...2048).contains(h) else { throw ConnectionFailure.validationFailed }
        frame = CGRect(x: x, y: y, width: w, height: h)
        viewportWidth = viewport; self.radius = radius; self.visible = visible == 1 && w >= 160 && h >= 120
    }
    func nativeFrame(in bounds: CGRect) -> CGRect? {
        let scale = bounds.width / viewportWidth
        let result = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        guard visible, bounds.contains(result) else { return nil }
        return result
    }
}

#if os(iOS)
private typealias MapContainerView = UIView
#else
private typealias MapContainerView = NSView
#endif

@MainActor
private final class MapLoadingDelegate: NSObject, MKMapViewDelegate {
    var onFailure: (() -> Void)?
    var onRegionChange: (() -> Void)?
    var onLocation: ((CLLocation) -> Void)?
    var onLocationFailure: (() -> Void)?
    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        if let location = userLocation.location { onLocation?(location) }
    }
    func mapView(_ mapView: MKMapView, didFailToLocateUserWithError error: Error) { onLocationFailure?() }
    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) { onRegionChange?() }
    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) { onFailure?() }
}

@MainActor
private final class InteractiveMapSurface: MapContainerView {
    let map = MKMapView(frame: .zero)
    var destination: MKMapItem?
    let loadingDelegate = MapLoadingDelegate()
    var onTap: (() -> Void)?
    private var pendingTap: Task<Void, Never>?
    private var locationManager: CLLocationManager?
    private var locationDeadline: Task<Void, Never>?
    private var locationWanted = false
    private var fittedLocation = false
    private(set) var fullscreen = false
    #if os(iOS)
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(cancelDoubleTap))
    #else
    private lazy var tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
    private lazy var doubleTap = NSClickGestureRecognizer(target: self, action: #selector(cancelDoubleTap))
    #endif
    #if os(iOS)
    private let openButton = UIButton(type: .system)
    private let locationButton = UIButton(type: .system)
    #else
    private let openButton = NSButton(title: "Open in Maps", target: nil, action: nil)
    private let locationButton = NSButton(title: "Show my location", target: nil, action: nil)
    #endif
    init() {
        super.init(frame: .zero)
        #if os(iOS)
        clipsToBounds = true
        openButton.setTitle("Open in Maps", for: .normal)
        openButton.backgroundColor = .systemBackground
        openButton.layer.cornerRadius = 8
        openButton.addTarget(self, action: #selector(openDestination), for: .touchUpInside)
        locationButton.backgroundColor = .systemBackground
        locationButton.layer.cornerRadius = 8
        locationButton.addTarget(self, action: #selector(toggleLocation), for: .touchUpInside)
        #else
        wantsLayer = true; layer?.masksToBounds = true
        openButton.target = self; openButton.action = #selector(openDestination)
        openButton.bezelStyle = .rounded
        locationButton.target = self; locationButton.action = #selector(toggleLocation)
        locationButton.bezelStyle = .rounded
        #endif
        map.delegate = loadingDelegate
        map.showsUserLocation = false
        map.isZoomEnabled = true; map.isScrollEnabled = true
        map.isRotateEnabled = false; map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.mapType = .standard
        addSubview(map); addSubview(openButton); addSubview(locationButton)
        locationButton.isHidden = true
        locationTitle("Show my location")
        loadingDelegate.onLocation = { [weak self] in self?.receivedLocation($0) }
        loadingDelegate.onLocationFailure = { [weak self] in self?.locationUnavailable() }
        tap.delegate = self; doubleTap.delegate = self
        #if os(iOS)
        tap.cancelsTouchesInView = false; tap.delaysTouchesEnded = false
        doubleTap.cancelsTouchesInView = false; doubleTap.delaysTouchesEnded = false
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        #else
        tap.buttonMask = 1; doubleTap.buttonMask = 1; doubleTap.numberOfClicksRequired = 2
        #endif
        map.addGestureRecognizer(tap); map.addGestureRecognizer(doubleTap)
        loadingDelegate.onRegionChange = { [weak self] in self?.cancelTap() }
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func resize(radius: CGFloat) {
        #if os(iOS)
        layer.cornerRadius = radius
        #else
        layer?.cornerRadius = radius
        #endif
        map.frame = bounds
        #if os(iOS)
        openButton.frame = CGRect(x: max(8, bounds.width - 144), y: 8, width: 136, height: 36)
        locationButton.frame = CGRect(x: max(8, bounds.width - 184), y: 52, width: 176, height: 36)
        #else
        openButton.frame = CGRect(x: max(8, bounds.width - 144), y: max(8, bounds.height - 44), width: 136, height: 36)
        locationButton.frame = CGRect(x: max(8, bounds.width - 184), y: max(8, bounds.height - 88), width: 176, height: 36)
        #endif
    }
    func setFullscreen(_ value: Bool) {
        guard fullscreen != value else { return }
        cancelTap(); fullscreen = value; locationButton.isHidden = !value
        if !value { stopLocation() }
    }
    private func locationTitle(_ title: String) {
        #if os(iOS)
        locationButton.setTitle(title, for: .normal)
        #else
        locationButton.title = title
        #endif
    }
    private var isForeground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        NSApplication.shared.isActive && !NSApplication.shared.isHidden
        #endif
    }
    @objc private func toggleLocation() {
        cancelTap()
        guard fullscreen, !isHidden, window != nil, isForeground else { return }
        if locationWanted { stopLocation(); return }
        locationWanted = true; fittedLocation = false
        if locationManager == nil {
            let manager = CLLocationManager(); manager.delegate = self
            locationManager = manager
        }
        if locationManager?.authorizationStatus == .notDetermined {
            locationTitle("Allow location access")
            // Permission can only be requested by this native button.
            locationManager?.requestWhenInUseAuthorization()
        } else { resumeLocation() }
    }
    func resumeLocation() {
        guard locationWanted, fullscreen, !isHidden, window != nil, isForeground else { return }
        switch locationManager?.authorizationStatus {
        case .authorizedAlways?, .authorizedWhenInUse?:
            guard !map.showsUserLocation else { return }
            locationTitle("Finding your location…")
            map.showsUserLocation = true
            locationDeadline?.cancel()
            locationDeadline = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.locationUnavailable()
            }
        case .denied?, .restricted?: locationUnavailable()
        default: break
        }
    }
    func suspendLocation() {
        cancelTap(); locationDeadline?.cancel(); locationDeadline = nil
        map.showsUserLocation = false
        locationManager?.stopUpdatingLocation()
    }
    func stopLocation() {
        locationWanted = false; fittedLocation = false
        suspendLocation(); locationTitle("Show my location")
    }
    private func locationUnavailable() {
        guard locationWanted else { return }
        stopLocation(); locationTitle("Location unavailable")
    }
    private func receivedLocation(_ location: CLLocation) {
        guard locationWanted, fullscreen, isForeground, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 60 else { return }
        locationDeadline?.cancel(); locationDeadline = nil
        locationTitle("Hide my location")
        guard !fittedLocation, let destination else { return }
        fittedLocation = true
        let a = MKMapPoint(location.coordinate), b = MKMapPoint(destination.placemark.coordinate)
        let rect = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y),
                             width: max(1000, abs(a.x-b.x)), height: max(1000, abs(a.y-b.y)))
        // Fit both points once. Later location updates never fight user panning.
        #if os(iOS)
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 100, left: 48, bottom: 48, right: 48), animated: true)
        #else
        map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 100, left: 48, bottom: 48, right: 48), animated: true)
        #endif
    }
    func cancelTap() { pendingTap?.cancel(); pendingTap = nil }
    @objc private func cancelDoubleTap() { cancelTap() }
    @objc private func tapped() {
        guard !fullscreen else { return }
        // Delay single-tap delivery so native double-tap zoom and region changes
        // can cancel it. Never cancel or replace MapKit gesture recognizers.
        if pendingTap != nil { cancelTap(); return }
        pendingTap = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingTap = nil
            guard !self.isHidden, self.window != nil else { return }
            self.onTap?()
        }
    }
    @objc private func openDestination() {
        cancelTap()
        // Only this native control can open the originally resolved destination.
        destination?.openInMaps(launchOptions: nil)
    }
}

extension InteractiveMapSurface: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { resumeLocation() }
}

#if os(iOS)
extension InteractiveMapSurface: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard map.bounds.insetBy(dx: 32, dy: 40).contains(touch.location(in: map)) else { return false }
        var view = touch.view
        while let current = view, current !== map {
            if current is UIControl || current is MKAnnotationView { return false }
            view = current.superview
        }
        return view === map
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#else
extension InteractiveMapSurface: NSGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        if gestureRecognizer === tap && event.clickCount != 1 { cancelTap(); return false }
        guard map.bounds.insetBy(dx: 32, dy: 40).contains(map.convert(event.locationInWindow, from: nil)) else { return false }
        var view = map.hitTest(convert(event.locationInWindow, from: nil))
        while let current = view, current !== map {
            if current is NSControl || current is MKAnnotationView { return false }
            view = current.superview
        }
        return view === map
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
        gestureRecognizer === tap && other === doubleTap
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }
}
#endif

/// A single address-derived map above the package WebView. Page JavaScript only
/// controls its rectangle/lifetime; gestures and map networking stay native.
@MainActor
final class InteractiveMapController {
    var onTap: ((String) -> Void)?
    private weak var webView: WKWebView?
    private var surface: InteractiveMapSurface?
    private var id: String?
    private var address: String?
    private var state = "stopped"
    private let geocoder = CLGeocoder()
    private var task: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var heartbeat = Date.distantPast
    private var lastStart = Date.distantPast
    func attach(_ view: WKWebView) {
        webView = view
        #if os(iOS)
        let hidden = UIApplication.didEnterBackgroundNotification
        let inactive = UIApplication.willResignActiveNotification
        let active = UIApplication.didBecomeActiveNotification
        #else
        let hidden = NSApplication.didHideNotification
        let inactive = NSApplication.didResignActiveNotification
        let active = NSApplication.didBecomeActiveNotification
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: hidden, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: inactive, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.surface?.suspendLocation() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.surface?.resumeLocation() }
        })
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(self.heartbeat) > 3 { self.close() }
            }
        }
    }
    func close() {
        task?.cancel(); task = nil; geocoder.cancelGeocode()
        surface?.stopLocation(); surface?.removeFromSuperview(); surface = nil
        id = nil; address = nil; state = "stopped"
    }
    func cancel() {
        close(); monitor?.cancel(); monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    }
    static func validate(operation: String, parameters: [String: String]) throws {
        guard let id = parameters["id"], id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw ConnectionFailure.validationFailed }
        if let mode = parameters["mode"], mode != "embedded" && mode != "fullscreen" { throw ConnectionFailure.validationFailed }
        if parameters["mode"] == "fullscreen", let text = parameters["rect"] {
            let bounds = try NativeMapBounds(text)
            guard bounds.frame.width >= 320, bounds.frame.height >= 240 else { throw ConnectionFailure.validationFailed }
        }
        let keys = Set(parameters.keys).subtracting(operation == "close" ? [] : ["mode"])
        switch operation {
        case "close": guard keys == ["id"] else { throw ConnectionFailure.validationFailed }
        case "update":
            guard keys == ["id", "rect"], let rect = parameters["rect"] else { throw ConnectionFailure.validationFailed }
            _ = try NativeMapBounds(rect)
        case "present":
            guard keys == ["id", "address", "rect"], let address = parameters["address"], let rect = parameters["rect"] else { throw ConnectionFailure.validationFailed }
            _ = try MapPreviewRequest(["address": address]); _ = try NativeMapBounds(rect)
        default: throw ConnectionFailure.validationFailed
        }
    }
    func request(operation: String, parameters: [String: String]) throws -> [String: String] {
        try Self.validate(operation: operation, parameters: parameters)
        let requestID = parameters["id"]!
        if operation == "close" { if id == requestID { close() }; return ["state": "stopped"] }
        guard let webView else { throw ConnectionFailure.deviceOffline }
        #if os(iOS)
        guard UIApplication.shared.applicationState != .background else { close(); return ["state": "stopped"] }
        if UIApplication.shared.applicationState != .active {
            surface?.suspendLocation()
            // OS permission sheets temporarily deactivate the app. Maintain an
            // existing lease without starting new native work during the sheet.
            if operation == "update", id == requestID { heartbeat = Date(); return ["state": state] }
            return ["state": "stopped"]
        }
        #else
        guard webView.window?.isVisible == true, (webView.window?.alphaValue ?? 0) > 0, !NSApplication.shared.isHidden else { close(); return ["state": "stopped"] }
        #endif
        let rect = try NativeMapBounds(parameters["rect"]!)
        if operation == "present" {
            let requestedAddress = try MapPreviewRequest(["address": parameters["address"]!]).address
            if id != requestID || address != requestedAddress {
                guard Date().timeIntervalSince(lastStart) >= 2 else { throw ConnectionFailure.sizeLimit }
                close(); lastStart = Date(); id = requestID; address = requestedAddress; state = "loading"
                task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let deadline = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 12_000_000_000)
                        if !Task.isCancelled { self?.geocoder.cancelGeocode() }
                    }
                    defer { deadline.cancel() }
                    do {
                        let places = try await self.geocoder.geocodeAddressString(requestedAddress)
                        try Task.checkCancellation()
                        guard self.id == requestID else { return }
                        guard !places.isEmpty else { self.state = "not_found"; return }
                        guard places.count == 1, let place = places.first, place.thoroughfare != nil, let location = place.location else { self.state = "ambiguous"; return }
                        let surface = InteractiveMapSurface(); surface.isHidden = true
                        surface.onTap = { [weak self, weak surface] in
                            guard let self, self.id == requestID, self.surface === surface,
                                  self.state == "ready", Date().timeIntervalSince(self.heartbeat) <= 3 else { return }
                            self.onTap?(requestID)
                        }
                        surface.destination = MKMapItem(placemark: MKPlacemark(placemark: place))
                        let annotation = MKPointAnnotation(); annotation.coordinate = location.coordinate
                        surface.map.addAnnotation(annotation)
                        surface.map.setRegion(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: false)
                        surface.loadingDelegate.onFailure = { [weak self] in
                            if self?.id == requestID { self?.state = "failed" }
                        }
                        self.surface = surface; self.webView?.addSubview(surface); self.state = "ready"
                        // Remain hidden until the next fresh rectangle update.
                    } catch {
                        guard !Task.isCancelled, self.id == requestID else { return }
                        self.state = (error as? CLError)?.code == .geocodeFoundNoResult ? "not_found" : "failed"
                    }
                }
            }
        }
        guard id == requestID else { return ["state": "stopped"] }
        heartbeat = Date()
        if let surface {
            if var frame = rect.nativeFrame(in: webView.bounds) {
                #if os(macOS)
                if !webView.isFlipped { frame.origin.y = webView.bounds.height - frame.maxY }
                #endif
                surface.frame = frame; surface.resize(radius: rect.radius * webView.bounds.width / rect.viewportWidth)
                surface.isHidden = false
                surface.setFullscreen(parameters["mode"] == "fullscreen")
            } else { surface.stopLocation(); surface.isHidden = true }
        }
        return ["state": state]
    }
    deinit {
        monitor?.cancel(); task?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
