/// Copied from Brand/Style-Guide/dist/data.js. Do not invent a parallel system.
public enum BrandIdentity: Sendable {
    public static let sootHex = "#15191C"
    public static let porcelainHex = "#F4EFE5"
    public static let logomarkRevision = "8-bevel"
    public static let wordmarkRevision = "v1-modular"
    public static let defaultLockup = "stacked"
    public static let styleGuidePath = "Brand/Style-Guide"
    public static let styleGuideURL = "https://screenpunk-style-guide.gsuter.chatgpt.site"
    public static let electricCobaltHex = "#4276F6"
    public static let lightCanvasHex = "#F7F8FA"
}

public enum SemanticTokens: Sendable {
    public enum Light {
        public static let canvas = "#F7F8FA"
        public static let surface = "#FFFFFF"
        public static let raised = "#EEF1F5"
        public static let text = "#15191C"
        public static let textSecondary = "#58626A"
        public static let border = "#C9CCC9"
        public static let controlBorder = "#7B858D"
        public static let action = "#315DDD"
        public static let onAction = "#FFFFFF"
        public static let actionHover = "#244AB8"
        public static let selected = "#E4ECFF"
        public static let focus = "#315DDD"
        public static let success = "#176547"
        public static let warning = "#805607"
        public static let danger = "#A52C42"
    }

    public enum Dark {
        public static let canvas = "#15191C"
        public static let surface = "#20272C"
        public static let raised = "#30383B"
        public static let text = "#F4EFE5"
        public static let textSecondary = "#AFBAC2"
        public static let border = "#4B575E"
        public static let controlBorder = "#829098"
        public static let action = "#88A6FF"
        public static let onAction = "#15191C"
        public static let actionHover = "#A9BFFF"
        public static let selected = "#293B62"
        public static let focus = "#A58BFA"
        public static let success = "#55E0AF"
        public static let warning = "#EFC46D"
        public static let danger = "#FF8BA0"
    }
}

public enum PlatformRequirements: Sendable {
    public static let iosMinimum = "16.0"
    public static let macOSMinimum = "26.0"
    public static let appleSiliconOnly = true
    public static let ios27RequiredToRun = false
    public static let preferredControls = "ios27-style-guide"
    public static let controlFallback = "older-os-safe"
    public static let proposedIOSBundleID = "xyz.screenpunk.ios"
    public static let proposedMacBundleID = "xyz.screenpunk.macos"
}

public enum PackageLimits: Sendable {
    public static let compressedBytes = 25 * 1024 * 1024
    public static let expandedBytes = 50 * 1024 * 1024
    public static let maxFiles = 2_000
    public static let schemaMajor = 1
}

/// Offline ring uses Style-Guide danger tokens, not system red.
public enum OfflineOverlaySpec: Sendable {
    public static let ringPoints = 4
    public static let usesSystemRed = false
    public static let lightDangerHex = SemanticTokens.Light.danger
    public static let darkDangerHex = SemanticTokens.Dark.danger
    public static let label = "Offline"
    public static let holdSecondsForUnlink = 10
}
