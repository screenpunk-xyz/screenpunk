import Foundation
import AVFoundation
import OSLog
import WebKit
import ScreenpunkCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Native rendering shared by HA and future direct-source resolvers. The page
/// owns layout; native code owns credentials, decoding, lifetime and permissions.
@MainActor
final class CameraPlaybackController {
    @MainActor
    private final class Slot {
        let source: CameraSource
        let surface = CameraVideoSurface()
        var layer: AVPlayerLayer { surface.playerLayer }
        var task: Task<Void, Never>?
        var heartbeat = Date()
        var startedAt = Date()
        var gridFrame = CGRect.zero
        var order = 0
        var gallery = false
        var stream: CameraStream?
        var failure: String?
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        var progress = CameraPlaybackProgress()
        init(source: CameraSource) { self.source = source; layer.videoGravity = .resizeAspect }
        func stop() { task?.cancel(); layer.player?.pause(); layer.player = nil; surface.removeFromSuperview() }

    }
    private weak var webView: WKWebView?
    private let resolver: any CameraStreamResolver
    private let revision: String
    private var slots: [String: Slot] = [:]
    private var monitor: Task<Void, Never>?
    private var expandedId: String?
    private var backgroundObserver: NSObjectProtocol?
    init(resolver: any CameraStreamResolver, revision: String) {
        self.resolver = resolver; self.revision = revision
    }
    func attach(_ webView: WKWebView) {
        self.webView = webView
#if os(macOS)
        webView.wantsLayer = true
        let notification = NSApplication.didHideNotification
#else
        let notification = UIApplication.willResignActiveNotification
#endif
        backgroundObserver = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopAll() }
        }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                for (id, slot) in Array(self.slots) {
                    if Date().timeIntervalSince(slot.heartbeat) > 4 {
                        self.close(id); continue
                    }
                    if let stream = slot.stream, !(await stream.isAuthorized()), self.slots[id] === slot { self.close(id) }
                }
            }
        }
    }
    func stopAll() { slots.values.forEach { $0.stop() }; slots.removeAll(); expandedId = nil }
    func cancel() {
        stopAll(); monitor?.cancel(); monitor = nil
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
    }
    func close(_ id: String) {
        slots.removeValue(forKey: id)?.stop()
        if expandedId == id { expandedId = nil }
        layoutSlots()
    }
    private func layoutSlots() {
        guard let webView else { return }
        for (id, slot) in slots {
            slot.surface.isHidden = expandedId != nil && expandedId != id
            if slot.surface.model.expanded != (expandedId == id) { slot.surface.model.expanded = expandedId == id }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            slot.surface.frame = expandedId == id ? webView.bounds : slot.gridFrame
            CATransaction.commit()
        }
    }
    private func interact(_ action: String, id: String) {
        guard let slot = slots[id], slot.gallery else { return }
        switch action {
        case "refresh":
            slot.task?.cancel(); slot.layer.player?.pause(); slot.layer.player?.currentItem?.remove(slot.videoOutput); slot.layer.player = nil
            slot.progress = CameraPlaybackProgress(); slot.failure = nil; slot.stream = nil
            slot.startedAt = Date(); slot.surface.model.state = "loading"
            start(slot, id: id)
        case "expand": expandedId = id
        case "collapse": expandedId = nil
        case "next", "previous":
            guard expandedId == id else { return }
            let ids = slots.filter { $0.value.gallery }.sorted { $0.value.order < $1.value.order }.map(\.key)
            if let index = ids.firstIndex(of: id) {
                expandedId = ids[CameraGalleryNavigation.next(index: index, count: ids.count, direction: action == "next" ? 1 : -1)]
            }
        default: return
        }
        layoutSlots()
    }
    private func start(_ slot: Slot, id: String) {
        let resolver = self.resolver, revision = self.revision, source = slot.source
        slot.task = Task { @MainActor [weak self, weak slot] in
            do {
                let stream = try await resolver.resolveCamera(source, revision: revision)
                guard !Task.isCancelled, let self, let slot, self.slots[id] === slot else { return }
                slot.stream = stream
                let player = AVPlayer(url: stream.url)
                player.isMuted = true
                player.automaticallyWaitsToMinimizeStalling = true
                player.currentItem?.add(slot.videoOutput)
                slot.layer.player = player
                player.play()
            } catch {
                guard !Task.isCancelled, let slot else { return }
                slot.failure = (error as? ConnectionFailure)?.rawValue ?? "device_offline"
            }
        }
    }

    func request(operation: String, parameters: [String: String]) throws -> [String: String] {
        guard let id = parameters["id"], id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw ConnectionFailure.validationFailed
        }
        if operation == "cameraClose" { close(id); return ["state": "stopped"] }
        guard operation == "cameraPresent", let webView,
              let data = parameters["source"]?.data(using: .utf8),
              let source = try? JSONDecoder().decode(CameraSource.self, from: data),
              let rectData = parameters["rect"]?.data(using: .utf8),
              let rect = try? JSONDecoder().decode([String: Double].self, from: rectData),
              let x = rect["x"], let y = rect["y"], let w = rect["width"], let h = rect["height"],
              let viewport = rect["viewportWidth"], viewport > 0,
              [x,y,w,h,viewport].allSatisfy({ $0.isFinite && abs($0) <= 10000 }), w > 0, h > 0 else {
            throw ConnectionFailure.validationFailed
        }
#if os(iOS)
        guard UIApplication.shared.applicationState == .active else { close(id); return ["state": "stopped"] }
#else
        guard webView.window?.isVisible == true, !NSApplication.shared.isHidden else { close(id); return ["state": "stopped"] }
#endif
        if let old = slots[id], old.source != source { close(id) }
        let slot: Slot
        if let existing = slots[id] { slot = existing }
        else {
            guard slots.count < 3 else { throw ConnectionFailure.sizeLimit }
            slot = Slot(source: source); slots[id] = slot
            webView.addSubview(slot.surface)
            slot.surface.model.action = { [weak self] action in self?.interact(action, id: id) }
            start(slot, id: id)
        }
        slot.heartbeat = Date()
        slot.gallery = parameters["controls"] == "gallery"
        slot.order = Int(parameters["order"] ?? "0") ?? 0
        slot.surface.model.label = String((parameters["label"] ?? "Camera").prefix(80))
        slot.surface.setControlsVisible(slot.gallery)
        slot.layer.videoGravity = slot.gallery ? .resizeAspectFill : .resizeAspect
        let scale = webView.bounds.width / viewport
        var frame = CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
        // Reject clipped rectangles: do not stretch a partly scrolled video over nearby controls.
        guard webView.bounds.insetBy(dx: -1, dy: -1).contains(frame) else { close(id); return ["state": "stopped"] }
#if os(macOS)
        if !webView.isFlipped { frame.origin.y = webView.bounds.height - frame.maxY }
#endif
        slot.gridFrame = frame
        layoutSlots()
        let now = Date().timeIntervalSinceReferenceDate
        if let player = slot.layer.player {
            let time = player.currentTime()
            if slot.videoOutput.hasNewPixelBuffer(forItemTime: time) {
                var presentationTime = CMTime.invalid
                if slot.videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentationTime) != nil {
                    slot.progress.observe(presentationTime: presentationTime.seconds, now: now)
                }
            }
        }
        if slot.progress.timedOut(now: now, startedAt: slot.startedAt.timeIntervalSinceReferenceDate) {
            slot.failure = "device_offline"; slot.layer.player?.pause()
        }
        if let failure = slot.failure { slot.surface.model.state = "failed"; return ["state": "failed", "code": failure] }
        if slot.layer.player?.currentItem?.status == .failed {
            let error = slot.layer.player?.currentItem?.error as NSError?
            Logger(subsystem: "xyz.screenpunk", category: "camera").error("Camera playback failed: \(error?.domain ?? "unknown", privacy: .public) \(error?.code ?? 0)")
            slot.failure = "device_offline"
            slot.surface.model.state = "failed"
            return ["state": "failed", "code": "device_offline"]
        }
        let state = slot.layer.isReadyForDisplay && slot.progress.isLive(now: now) ? "playing" : "loading"
        slot.surface.model.state = state
        return ["state": state]
    }
}

/// A ready layer or advancing player clock alone does not prove live video.
struct CameraPlaybackProgress {
    private(set) var lastPresentationTime: Double?
    private(set) var lastFrameAt: TimeInterval?
    private(set) var advances = 0
    mutating func observe(presentationTime: Double, now: TimeInterval) {
        guard presentationTime.isFinite, presentationTime != lastPresentationTime else { return }
        if lastPresentationTime != nil { advances += 1 }
        lastPresentationTime = presentationTime
        lastFrameAt = now
    }
    func isLive(now: TimeInterval) -> Bool {
        advances >= 2 && lastFrameAt.map { now - $0 <= 3 } == true
    }
    func timedOut(now: TimeInterval, startedAt: TimeInterval) -> Bool {
        if advances >= 2, let lastFrameAt { return now - lastFrameAt > 15 }
        return now - startedAt > 75
    }
}
