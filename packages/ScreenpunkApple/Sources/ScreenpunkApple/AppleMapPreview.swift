import Foundation
import MapKit
import WebKit
import ScreenpunkCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MapPreviewRequest: Equatable {
    let address: String
    let width: Int
    let height: Int
    init(_ parameters: [String: String]) throws {
        guard Set(parameters.keys).isSubset(of: ["address", "width", "height"]),
              let address = parameters["address"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty, address.utf8.count <= 512,
              !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !address.contains("://"),
              let width = Int(parameters["width"] ?? "640"), (160...1024).contains(width),
              let height = Int(parameters["height"] ?? "360"), (120...768).contains(height) else { throw ConnectionFailure.validationFailed }
        self.address = address; self.width = width; self.height = height
    }
}

/// Address-only Apple service access. No URL transport or device location access.
@MainActor
final class AppleMapPreview {
    static func isDeclared(in manifest: DashboardManifest, operation: String = "snapshot") -> Bool {
        manifest.connections.contains { connection in
            guard connection.alias == "appleMaps", connection.publicHTTP == nil, connection.serviceCalls == nil, connection.cameraEntities == nil,
                  let operations = connection.operations, !operations.isEmpty else { return false }
            let names = operations.map(\.name)
            return Set(names).count == names.count && names.contains(operation) &&
                operations.allSatisfy { ["snapshot", "present", "update", "close"].contains($0.name) && $0.kind == "http" && $0.maxAgeSeconds == nil }
        }
    }
    private let geocoder = CLGeocoder()
    private var snapshotter: MKMapSnapshotter?
    private var busy = false
    private var lastRequest = Date.distantPast
    func cancel() { geocoder.cancelGeocode(); snapshotter?.cancel() }
    func render(_ request: MapPreviewRequest) async throws -> (Data?, String) {
        guard !busy, Date().timeIntervalSince(lastRequest) >= 2 else { throw ConnectionFailure.sizeLimit }
        busy = true; lastRequest = Date()
        defer { busy = false; snapshotter = nil }
        return try await withTaskCancellationHandler(operation: {
            let places: [CLPlacemark]
            do { places = try await geocoder.geocodeAddressString(request.address) }
            catch let error as CLError where error.code == .geocodeFoundNoResult { return (nil, "not_found") }
            try Task.checkCancellation()
            guard !places.isEmpty else { return (nil, "not_found") }
            guard places.count == 1, let place = places.first, place.thoroughfare != nil, let coordinate = place.location?.coordinate else { return (nil, "ambiguous") }
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)
            options.size = CGSize(width: request.width, height: request.height)
            #if os(iOS)
            options.scale = 1
            #endif
            options.mapType = .standard
            options.showsBuildings = false
            options.pointOfInterestFilter = .excludingAll
            let snapshotter = MKMapSnapshotter(options: options); self.snapshotter = snapshotter
            let snapshot = try await snapshotter.start()
            try Task.checkCancellation()
            // Preserve the full snapshot; add the address marker and attribution outside its labels.
            let point = snapshot.point(for: coordinate)
            #if os(macOS)
            let image = NSImage(size: NSSize(width: request.width, height: request.height + 24))
            image.lockFocus()
            NSColor.white.setFill(); NSRect(origin: .zero, size: image.size).fill()
            snapshot.image.draw(in: NSRect(x: 0, y: 24, width: request.width, height: request.height))
            NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 8, y: point.y + 16, width: 16, height: 16)).fill()
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 6, y: point.y + 18, width: 12, height: 12)).fill()
            ("Apple Maps" as NSString).draw(at: NSPoint(x: 8, y: 5), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw ConnectionFailure.validationFailed }
            #else
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: request.width, height: request.height + 24), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: request.width, height: request.height + 24))
                snapshot.image.draw(at: .zero)
                UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)).fill()
                UIColor.systemRed.setFill(); UIBezierPath(ovalIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)).fill()
                ("Apple Maps" as NSString).draw(at: CGPoint(x: 8, y: request.height + 5), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black])
            }
            guard let data = image.pngData() else { throw ConnectionFailure.validationFailed }
            #endif
            return (data, "ready")
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }
}

@MainActor
final class MapPreviewApproval {
    private var prompting = false
    #if os(macOS)
    private let defaults = UserDefaults(suiteName: "xyz.screenpunk.maps")!
    #else
    private let defaults = UserDefaults.standard
    #endif
    func allowed(dashboard: String, revision: String, view: WKWebView?) -> Bool {
        let key = "appleMaps.approved." + PeerPin.hex(PeerPin.sha256(Data((dashboard + "\n" + revision).utf8)))
        if defaults.bool(forKey: key) { return true }
        guard !prompting, let view, view.window != nil else { return false }
        #if os(macOS)
        guard view.window?.isVisible == true, (view.window?.alphaValue ?? 0) > 0 else { return false }
        #endif
        prompting = true
        let message = "Allow this screen revision to send supplied addresses to Apple for map previews? Device location is optional and only requested when you press Show my location in a fullscreen map."
        #if os(macOS)
        let alert = NSAlert(); alert.messageText = "Allow Apple Maps previews?"; alert.informativeText = message
        alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: view.window!) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.defaults.set(true, forKey: key) }
            self?.prompting = false
        }
        #else
        guard var presenter = view.window?.rootViewController else { prompting = false; return false }
        while let presented = presenter.presentedViewController { presenter = presented }
        let alert = UIAlertController(title: "Allow Apple Maps previews?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Allow", style: .default) { [weak self] _ in
            self?.defaults.set(true, forKey: key); self?.prompting = false
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in self?.prompting = false })
        presenter.present(alert, animated: true)
        #endif
        return false
    }
}
