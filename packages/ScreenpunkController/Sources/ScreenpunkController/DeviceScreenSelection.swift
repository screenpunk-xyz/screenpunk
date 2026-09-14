import Foundation

/// A device's ordered draft selection. Changing selection never deploys a package.
public struct DeviceScreenSelection: Codable, Equatable, Sendable {
    public static let limit = 12
    public private(set) var multiple: Bool
    public private(set) var ids: [String]

    public init(ids: [String] = [], multiple: Bool = false) {
        var unique: [String] = []
        for id in ids where !id.isEmpty && !unique.contains(id) { unique.append(id) }
        self.multiple = multiple
        self.ids = Array(unique.prefix(multiple ? Self.limit : 1))
    }

    public mutating func setMultiple(_ enabled: Bool, preferred: String?) {
        multiple = enabled
        if !enabled { ids = (preferred.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first).map { [$0] } ?? [] }
    }

    /// False means the selection limit was reached; the previous draft is retained.
    @discardableResult public mutating func choose(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        if !multiple { ids = [id]; return true }
        if ids.contains(id) { ids.removeAll { $0 == id }; return true }
        guard ids.count < Self.limit else { return false }
        ids.append(id)
        return true
    }

    public static func matches(name: String, query: String) -> Bool {
        query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            name.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
