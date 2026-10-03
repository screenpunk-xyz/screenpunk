import Foundation
#if os(macOS)
import Darwin

struct WorkspaceProjectInventory {
    var files = 0
    var members = 0
    var bytes: Int64 = 0
    var omitted: [String] = []
    var includedFiles = Set<String>()
    var directories = Set<String>()
}

/// Uses the portable spelling rule even on a case-insensitive local volume.
struct WorkspacePathCollisionDetector {
    private var paths = Set<String>()
    mutating func insert(_ path: String) throws {
        guard paths.insert(WorkspaceValidation.portableKey(path)).inserted else { throw WorkspaceError.conflict }
    }
}

enum WorkspaceIgnoreSource {
    case current, absent, staged(Data)
}

struct WorkspaceIgnoreRules {
    private let patterns: [NSRegularExpression]
    let hasFile: Bool

    init(root: WorkspaceFiles, project: [String], readBudget: WorkspaceReadBudget? = nil) throws {
        let fd = try root.directory(project); defer { close(fd) }
        let data = try root.exists(fd, ".screenpunkignore")
            ? root.read(fd, ".screenpunkignore", maxBytes: 64 * 1024, readBudget: readBudget) : nil
        try self.init(data: data, readBudget: readBudget)
    }

    init(data: Data?, readBudget: WorkspaceReadBudget? = nil) throws {
        guard let data else { patterns = []; hasFile = false; return }
        hasFile = true
        guard data.count <= 64 * 1024 else { throw WorkspaceError.limitExceeded }
        guard let source = String(data: data, encoding: .utf8) else { throw WorkspaceError.invalidSchema }
        let lines = source.components(separatedBy: .newlines)
        guard lines.count <= 256 else { throw WorkspaceError.limitExceeded }
        patterns = try lines.compactMap { line in
            try readBudget?.check()
            let rule = line.trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty, !rule.hasPrefix("#") else { return nil }
            guard rule.utf8.count <= 256, WorkspaceValidation.member(rule),
                  !rule.hasPrefix("!"), !rule.contains(where: { "[]{}".contains($0) }) else { throw WorkspaceError.invalidSchema }
            var expression = rule.contains("/") ? "^" : "(?:^|/)"
            let characters = Array(rule)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        expression += "(?:.*/)?"; index += 3; continue
                    }
                    expression += ".*"; index += 2; continue
                }
                if character == "*" { expression += "[^/]*" }
                else if character == "?" { expression += "[^/]" }
                else { expression += NSRegularExpression.escapedPattern(for: String(character)) }
                index += 1
            }
            expression += "(?:/.*)?$"
            guard let compiled = try? NSRegularExpression(pattern: expression) else { throw WorkspaceError.invalidSchema }
            return compiled
        }
    }

    func excludes(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return patterns.contains { $0.firstMatch(in: path, range: range) != nil }
    }
}

enum WorkspaceProjectedSourcePolicy {
    static func validate(current: WorkspaceIgnoreRules, projected: WorkspaceIgnoreRules,
                         targets: [String], required: [String]) throws {
        for path in targets {
            guard WorkspaceValidation.member(path), !WorkspaceFiles.fixedSourceExcludes(path),
                  !current.excludes(path), !projected.excludes(path) else { throw WorkspaceError.invalidSchema }
        }
        for path in required {
            guard WorkspaceValidation.member(path), !WorkspaceFiles.fixedSourceExcludes(path),
                  !projected.excludes(path) else { throw WorkspaceError.invalidSchema }
        }
    }
}

extension WorkspaceFiles {
    /// Fixed exclusions apply to any component; a project-specific ignore can only remove more.
    static func fixedSourceExcludes(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let name = WorkspaceValidation.portableKey(String(component))
            return name == "node_modules" || name == "dist" || name.hasPrefix(".") && path != ".screenpunkignore"
        }
    }

    /// Read-only bounded inventory. Required project members are checked against this same
    /// filter, so coverage cannot claim a source entry that the inventory omitted.
    func inventory(_ project: [String], retained: Bool = false, memberLimit: Int? = nil,
                   readBudget: WorkspaceReadBudget? = nil, required: [String] = [],
                   ignoreSource: WorkspaceIgnoreSource = .current) throws -> WorkspaceProjectInventory {
        try readBudget?.check()
        var result = WorkspaceProjectInventory()
        var collisions = WorkspacePathCollisionDetector()
        let rules: WorkspaceIgnoreRules?
        if retained { rules = nil }
        else {
            switch ignoreSource {
            case .current: rules = try WorkspaceIgnoreRules(root: self, project: project, readBudget: readBudget)
            case .absent: rules = try WorkspaceIgnoreRules(data: nil, readBudget: readBudget)
            case .staged(let data): rules = try WorkspaceIgnoreRules(data: data, readBudget: readBudget)
            }
        }
        let requiresOnDiskIgnore: Bool
        if case .current = ignoreSource { requiresOnDiskIgnore = true } else { requiresOnDiskIgnore = false }
        let requiredFiles = required + (requiresOnDiskIgnore && rules?.hasFile == true ? [".screenpunkignore"] : [])
        guard retained || requiredFiles.allSatisfy({ !Self.fixedSourceExcludes($0) && rules?.excludes($0) != true }) else {
            throw WorkspaceError.invalidSchema
        }
        let ceiling = min(memberLimit ?? (retained ? 1_000_000 : 2_000), retained ? 1_000_000 : 2_000)
        guard ceiling >= 0 else { throw WorkspaceError.limitExceeded }
        try visit(project, relative: [], depth: 0, retained: retained, ceiling: ceiling,
                  rules: rules, readBudget: readBudget, result: &result, collisions: &collisions)
        guard retained || requiredFiles.allSatisfy(result.includedFiles.contains) else { throw WorkspaceError.unsafeFile }
        return result
    }

    private func visit(_ parts: [String], relative: [String], depth: Int, retained: Bool,
                       ceiling: Int, rules: WorkspaceIgnoreRules?, readBudget: WorkspaceReadBudget?,
                       result: inout WorkspaceProjectInventory,
                       collisions: inout WorkspacePathCollisionDetector) throws {
        try readBudget?.check()
        guard depth <= 32 else { throw WorkspaceError.limitExceeded }
        let directoryFD = try directory(parts)
        defer { close(directoryFD) }
        try readBudget?.requireLocal(directoryFD)
        let duplicate = dup(directoryFD)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }; throw WorkspaceError.unavailable
        }
        defer { closedir(stream) }
        while true {
            try readBudget?.check()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw WorkspaceError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name, name != ".", name != ".." else {
                if name == nil { throw WorkspaceError.unsafeFile }
                continue
            }
            guard WorkspaceValidation.member(name), !name.contains("/") else { throw WorkspaceError.invalidPath }
            guard result.members < ceiling else { throw WorkspaceError.limitExceeded }
            result.members += 1 // Included files, directories and omissions all consume budget.
            let child = relative + [name]
            let member = child.joined(separator: "/")
            let fullPath = (parts + [name]).joined(separator: "/")
            var metadata = stat()
            guard fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0,
                  metadata.st_mode & 0o7000 == 0 else { throw WorkspaceError.unsafeFile }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFDIR) ||
                    (kind == mode_t(S_IFREG) && metadata.st_nlink == 1 && metadata.st_size >= 0) else {
                throw WorkspaceError.unsafeFile
            }
            if kind == mode_t(S_IFDIR) { result.directories.insert(member) }
            if !retained && (Self.fixedSourceExcludes(member) || rules?.excludes(member) == true) {
                result.omitted.append(fullPath)
                continue
            }
            try collisions.insert(member)
            switch kind {
            case mode_t(S_IFDIR):
                try visit(parts + [name], relative: child, depth: depth + 1, retained: retained,
                          ceiling: ceiling, rules: rules, readBudget: readBudget,
                          result: &result, collisions: &collisions)
            case mode_t(S_IFREG):
                guard metadata.st_nlink == 1, metadata.st_size >= 0,
                      retained || metadata.st_size <= 5 * 1024 * 1024 else { throw WorkspaceError.unsafeFile }
                guard result.files < (retained ? 1_000_000 : 2_000),
                      metadata.st_size <= (retained ? 64 * 1024 * 1024 * 1024 : 25 * 1024 * 1024) - result.bytes else {
                    throw WorkspaceError.limitExceeded
                }
                result.files += 1
                result.bytes += metadata.st_size
                if !retained { result.includedFiles.insert(member) }
            default: throw WorkspaceError.unsafeFile
            }
        }
    }
}
#endif
