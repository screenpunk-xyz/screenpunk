import Foundation
import ScreenpunkCore

public struct PreviewRequest: Sendable, Equatable {
    public var dashboardId: String
    public var revision: String
    public var digest: String
    public var packageDirectory: URL
    public var width: Int
    public var height: Int
    public var live: Bool
    /// Strict runtime readiness remains the default for review/deployment previews.
    public var waitsForRuntimeReady: Bool
    public var timeoutSeconds: TimeInterval
    public var interaction: PreviewInteraction?
    /// Native process input only; never logged, put in an environment variable, or returned by MCP.
    public var nativeHomeAssistant: HomeAssistantProvisioning?
    public var nativePublicReads: PublicReadProvisioning?

    public init(
        dashboardId: String,
        revision: String,
        digest: String,
        packageDirectory: URL,
        width: Int,
        height: Int,
        live: Bool = true,
        waitsForRuntimeReady: Bool = true,
        timeoutSeconds: TimeInterval = TimeInterval(RuntimeBounds.readyTimeoutSeconds),
        interaction: PreviewInteraction? = nil,
        nativeHomeAssistant: HomeAssistantProvisioning? = nil,
        nativePublicReads: PublicReadProvisioning? = nil
    ) {
        self.dashboardId = dashboardId
        self.revision = revision
        self.digest = digest
        self.packageDirectory = packageDirectory
        self.width = width
        self.height = height
        self.live = live
        self.waitsForRuntimeReady = waitsForRuntimeReady
        self.timeoutSeconds = timeoutSeconds
        self.interaction = interaction
        self.nativeHomeAssistant = nativeHomeAssistant
        self.nativePublicReads = nativePublicReads
    }
}

public struct PreviewInteraction: Sendable, Equatable {
    public var kind: String
    public var x: Double?
    public var y: Double?
    public var text: String?
    public var dy: Double?

    public init(kind: String, x: Double? = nil, y: Double? = nil, text: String? = nil, dy: Double? = nil) {
        self.kind = kind
        self.x = x
        self.y = y
        self.text = text
        self.dy = dy
    }
}

public struct PreviewCapture: Sendable, Equatable {
    public var png: Data
    public var width: Int
    public var height: Int
    public var revision: String
    public var digest: String
    public var renderingPlatform: String
    public var live: Bool
    public var connectionHealth: String
    public var diagnostics: [String]
    public var interactionNote: String?

    public init(
        png: Data,
        width: Int,
        height: Int,
        revision: String,
        digest: String,
        renderingPlatform: String = "macOS-preview",
        live: Bool,
        connectionHealth: String,
        diagnostics: [String],
        interactionNote: String? = nil
    ) {
        self.png = png
        self.width = width
        self.height = height
        self.revision = revision
        self.digest = digest
        self.renderingPlatform = renderingPlatform
        self.live = live
        self.connectionHealth = connectionHealth
        self.diagnostics = diagnostics
        self.interactionNote = interactionNote
    }
}

public protocol PreviewRenderer: Sendable {
    func render(_ request: PreviewRequest) throws -> PreviewCapture
}

/// Test double. Production MCP never uses this when a helper capture fails.
public struct InjectedPreviewRenderer: PreviewRenderer {
    public var capture: PreviewCapture?
    public var error: ControllerError?

    public init(capture: PreviewCapture? = nil, error: ControllerError? = nil) {
        self.capture = capture
        self.error = error
    }

    public func render(_ request: PreviewRequest) throws -> PreviewCapture {
        if let error { throw error }
        guard var capture else {
            throw ControllerError.snapshotUnavailable(reason: "injected_missing")
        }
        capture.revision = request.revision
        capture.digest = request.digest
        capture.live = request.live
        if let interaction = request.interaction {
            capture.interactionNote =
                "Live preview — \(interaction.kind) was sent to the preview surface and may control approved devices."
        }
        return capture
    }
}

public struct ProcessPreviewRenderer: PreviewRenderer {
    public var executableURL: URL
    public var extraEnvironment: [String: String]

    public init(executableURL: URL, extraEnvironment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.extraEnvironment = extraEnvironment
    }

    public func render(_ request: PreviewRequest) throws -> PreviewCapture {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenpunk-preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }

        let process = Process()
        process.executableURL = executableURL
        var environment = ProcessInfo.processInfo.environment
        environment["SCREENPUNK_SNAPSHOT"] = "1"
        environment["SCREENPUNK_PACKAGE_DIR"] = request.packageDirectory.path
        environment["SCREENPUNK_SNAPSHOT_OUT"] = out.path
        environment["SCREENPUNK_READY_TIMEOUT"] = String(Int(request.timeoutSeconds))
        environment["SCREENPUNK_PREVIEW_LIVE"] = request.live ? "1" : "0"
        environment["SCREENPUNK_DOCUMENT_THUMBNAIL"] = !request.live && !request.waitsForRuntimeReady ? "1" : "0"
        environment["SCREENPUNK_VIEWPORT_WIDTH"] = String(request.width)
        environment["SCREENPUNK_VIEWPORT_HEIGHT"] = String(request.height)
        if let interaction = request.interaction {
            environment["SCREENPUNK_INTERACT_KIND"] = interaction.kind
            if let x = interaction.x { environment["SCREENPUNK_INTERACT_X"] = String(x) }
            if let y = interaction.y { environment["SCREENPUNK_INTERACT_Y"] = String(y) }
            if let text = interaction.text { environment["SCREENPUNK_INTERACT_TEXT"] = text }
            if let dy = interaction.dy { environment["SCREENPUNK_INTERACT_DY"] = String(dy) }
        }
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        let err = Pipe()
        let nativeInput = Pipe()
        process.standardInput = nativeInput
        process.standardError = err
        process.standardOutput = Pipe()

        do {
            try process.run()
            if request.live {
                try nativeInput.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(NativePreviewConnections(homeAssistant: request.nativeHomeAssistant, publicReads: request.nativePublicReads)))
            }
            try nativeInput.fileHandleForWriting.close()
        } catch {
            throw ControllerError.snapshotUnavailable(reason: "helper_spawn_failed")
        }

        let deadline = Date().addingTimeInterval(request.timeoutSeconds + 5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw ControllerError.renderTimeout("preview helper exceeded \(Int(request.timeoutSeconds))s")
        }

        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if FileManager.default.fileExists(atPath: out.path) == false {
            if stderr.contains("SNAPSHOT_UNAVAILABLE") {
                throw ControllerError.snapshotUnavailable(reason: lastReason(in: stderr))
            }
            if stderr.contains("timeout") || stderr.contains("not_ready") {
                throw ControllerError.renderTimeout(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw ControllerError.snapshotUnavailable(reason: "no_image")
        }

        let png = try Data(contentsOf: out)
        guard PNGMagic.isPNG(png) else {
            try? FileManager.default.removeItem(at: out)
            throw ControllerError.snapshotUnavailable(reason: "not_png")
        }

        var diagnostics = ["helper=ScreenpunkPreviewHost", "activationPolicy=accessory"]
        if stderr.contains("SNAPSHOT_OK") {
            diagnostics.append("snapshot=ok")
        }
        var note: String?
        if let interaction = request.interaction {
            note = "Live preview — \(interaction.kind) was sent to the preview surface and may control approved devices."
        }
        return PreviewCapture(
            png: png,
            width: request.width,
            height: request.height,
            revision: request.revision,
            digest: request.digest,
            live: request.live,
            connectionHealth: "unknown",
            diagnostics: diagnostics,
            interactionNote: note
        )
    }

    private func lastReason(in stderr: String) -> String {
        if let line = stderr.split(separator: "\n").last(where: { $0.contains("SNAPSHOT_UNAVAILABLE") }) {
            if let reason = line.split(separator: "reason=").last {
                return String(reason)
            }
        }
        return "helper_unavailable"
    }
}
