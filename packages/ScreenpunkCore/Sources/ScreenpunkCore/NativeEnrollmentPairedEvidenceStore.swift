import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Explicit, unmounted local evidence persistence. This is not the production
/// management-transition store and confers no Keychain or installation authority.
final class NativeEnrollmentPairedEvidenceStore {
    enum Boundary: Equatable { case rootReserved, rootCreated, rootBound, rootSynchronized, sourceReserved, sourceCreated, sourceBound, sourceSynchronized, targetReserved, targetCreated, targetBound, targetSynchronized }
    /// Called only after the fixed command releases both journal locks. Delivered
    /// values describe historical local work; reentry cannot qualify its cursor.
    private let boundary: (Boundary) throws -> Void
    private let journal: NativeEnrollmentJournalStore
    /// Fixed synthetic stop only, never a callback or alternate filesystem backend.
    struct Fault: Equatable { let role: NativeJournalPairAssertion.Role; let boundary: NativeEnrollmentJournalStore.Boundary }
    private let fault: Fault?
    init(journal: NativeEnrollmentJournalStore, fault: Fault? = nil, boundary: @escaping (Boundary) throws -> Void = { _ in }) {
        self.journal = journal; self.fault = fault; self.boundary = boundary
    }
    final class Attempt {
        fileprivate let original: NativeEnrollmentJournalStore.PairAttempt
        fileprivate init(_ original: NativeEnrollmentJournalStore.PairAttempt) { self.original = original }
    }
    struct LocalPairDurabilityReceipt {
        let preparationID: UUID
        let completionAttemptID: UUID
        // No authority, secret proof, operational preparation, or public factory.
        fileprivate init(_ original: NativeEnrollmentJournalStore.PairAttempt, completion: UUID) {
            preparationID = original.preparationID; completionAttemptID = completion
        }
    }
    func beginOriginal(preparationID: UUID) throws -> Attempt { .init(try journal.capturePairOriginal(preparationID: preparationID, fault: fault)) }
    /// Restart reconstruction requires explicit current journal-tip recommit first.
    /// Unknown pending/unbound creation cannot be reconstructed or adopted.
    func recoverRecorded(preparationID: UUID) throws -> Attempt { .init(try journal.capturePairRecovery(preparationID: preparationID)) }
    func resumeRecorded(preparationID: UUID) throws -> Attempt {
        if try journal.hasRecordedPairInitialization(preparationID: preparationID) { return try recoverRecorded(preparationID: preparationID) }
        return try beginOriginal(preparationID: preparationID)
    }
    func continueExact(_ original: Attempt) throws -> LocalPairDurabilityReceipt {
        do {
            while let event = try journal.advancePairOriginal(original.original) {
                try boundary(event) // All descriptor/flock/mutex scopes have exited.
                try journal.verifyPairOriginal(original.original)
            }
            let id = try journal.qualifyPairOriginal(original.original)
            return .init(original.original, completion: id)
        } catch {
            journal.invalidatePairOriginal(original.original)
            throw error
        }
    }
}

/// Fixed descriptor commands only; there are no injected filesystem/backend
/// callbacks and no creation of ancestors. Names are bounded fixed protocol names.
enum NativePairFiles {
    static let directoryName = "evidence"
    static let historyName = "history.v3.json", enrollmentName = "enrollment.v1.json"
    static let sourceHistory = "history.source.pending", sourceEnrollment = "enrollment.source.pending"
    static let targetHistory = "history.target.pending", targetEnrollment = "enrollment.target.pending"
    static let allowed: Set<String> = [historyName, enrollmentName, sourceHistory, sourceEnrollment, targetHistory, targetEnrollment, "pair.lock", "pair-binding.json", "pair-binding.json.pending"]
    struct Payload {
        let history: Data, enrollment: Data
        init(history: Data, enrollment: Data) throws {
            guard history.count <= 65536, enrollment.count <= 1048576 else { throw NativeEnrollmentJournalError.capacity }
            self.history = history; self.enrollment = enrollment
        }
        init(_ p: NativeEnrollmentPreparationReconstructionProposal, target: Bool) throws {
            if target {
                history = try nativeEnrollmentBytes(p.targetHistory)
                enrollment = try NativeEnrollmentEvidenceCodec.encode(p.targetEnrollment, history: p.targetHistory)
            } else {
                history = try nativeEnrollmentBytes(p.source)
                enrollment = try p.source.enrollmentBytes(p.sourceEnrollment)
            }
            guard history.count <= 65536, enrollment.count <= 1048576 else { throw NativeEnrollmentJournalError.capacity }
        }
    }
    static func fail() -> NativeEnrollmentJournalError { .io(errno) }
    static func identity(_ fd: Int32, directory: Bool) throws -> NativeJournalIdentity {
        var s = stat(); guard fstat(fd, &s) == 0 else { throw fail() }
        guard (s.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG), directory || s.st_nlink == 1 else { throw NativeEnrollmentJournalError.unsafeRoot }
        return .init(device: UInt64(truncatingIfNeeded: s.st_dev), inode: UInt64(s.st_ino))
    }
    static func names(_ fd: Int32) throws -> Set<String> {
        let copy = dup(fd); guard copy >= 0 else { throw fail() }
        guard let stream = fdopendir(copy) else { close(copy); throw fail() }; defer { closedir(stream) }
        rewinddir(stream); var result = Set<String>()
        while true {
            errno = 0; guard let entry = readdir(stream) else { if errno != 0 { throw fail() }; break }
            let n = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            if n == "." || n == ".." { continue }
            guard n.utf8.count <= 64, result.count < 9, allowed.contains(n), result.insert(n).inserted else { throw NativeEnrollmentJournalError.outcomeUncertain }
        }
        return result
    }
    static func read(_ fd: Int32, _ name: String, limit: Int) throws -> NativeJournalNode? {
        let f = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard f >= 0 else { if errno == ENOENT { return nil }; throw fail() }; defer { close(f) }
        let id = try identity(f, directory: false); var st = stat()
        guard fstat(f, &st) == 0 else { throw fail() }
        guard st.st_size >= 0, st.st_size <= limit else { throw NativeEnrollmentJournalError.capacity }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = nativePairRead(f, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw fail() }; if n == 0 { break }
            guard bytes.count + n <= limit else { throw NativeEnrollmentJournalError.capacity }; bytes.append(contentsOf: buffer.prefix(n))
        }
        guard bytes.count == st.st_size, try identity(f, directory: false) == id else { throw NativeEnrollmentJournalError.conflict }
        return .init(identity: id, bytes: bytes)
    }
    static func create(_ fd: Int32, _ name: String) throws -> Int32 {
        let f = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard f >= 0 else { throw fail() }; return f
    }
    static func sync(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw fail() } }
    static func write(_ fd: Int32, bytes: Data) throws {
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else { throw fail() }
        try bytes.withUnsafeBytes { p in
            var offset = 0
            while offset < p.count {
                let n = nativePairWrite(fd, p.baseAddress!.advanced(by: offset), p.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw fail() }; guard n > 0 else { throw fail() }; offset += n
            }
        }
    }
    static func withRoot<T>(_ parent: Int32, root: NativeJournalPairRoot, cloudRootID: UUID, journalBinding: NativeJournalIdentity,
        allowEmptyBinding: Bool = false, _ operation: (Int32) throws -> T) throws -> T {
        let fd = openat(parent, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw fail() }; defer { close(fd) }
        guard try identity(fd, directory: true) == root.directory else { throw NativeEnrollmentJournalError.unsafeRoot }
        let lock = openat(fd, "pair.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK)
        guard lock >= 0 else { throw fail() }; defer { close(lock) }
        guard try identity(lock, directory: false) == root.lock,
            try read(fd, "pair.lock", limit: 8192) == NativeJournalNode(identity: root.lock, bytes: Data()) else { throw NativeEnrollmentJournalError.unsafeRoot }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NativeEnrollmentJournalError.outcomeUncertain }; defer { flock(lock, LOCK_UN) }
        _ = try names(fd)
        let value = NativeJournalPairRootBinding(schemaVersion: 1, cloudRootID: cloudRootID, journalBinding: journalBinding, root: root)
        let expected = try NativeJournalCodec.encode(value)
        guard expected.count <= 8192 else { throw NativeEnrollmentJournalError.capacity }
        let current = try read(fd, "pair-binding.json", limit: 8192), pending = try read(fd, "pair-binding.json.pending", limit: 8192)
        guard (current == nil) != (pending == nil), let binding = current ?? pending, binding.identity == root.binding,
            binding.bytes == expected || (allowEmptyBinding && current == nil && expected.starts(with: binding.bytes)) else { throw NativeEnrollmentJournalError.outcomeUncertain }
        let result = try operation(fd)
        guard try identity(fd, directory: true) == root.directory, try identity(lock, directory: false) == root.lock else { throw NativeEnrollmentJournalError.unsafeRoot }
        let reopened = openat(parent, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard reopened >= 0 else { throw fail() }; defer { close(reopened) }
        guard try identity(reopened, directory: true) == root.directory else { throw NativeEnrollmentJournalError.unsafeRoot }
        _ = try names(fd); return result
    }
    static func createRoot(_ parent: Int32, initializationAttemptID: UUID, reservationAttemptID: UUID, reservationIdentity: NativeJournalIdentity) throws -> NativeJournalPairRoot {
        guard mkdirat(parent, directoryName, 0o700) == 0 else { throw fail() }
        let fd = openat(parent, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw fail() }; defer { close(fd) }
        let lock = try create(fd, "pair.lock"); defer { close(lock) }
        let binding = try create(fd, "pair-binding.json.pending"); defer { close(binding) }
        let result = NativeJournalPairRoot(directory: try identity(fd, directory: true), lock: try identity(lock, directory: false), binding: try identity(binding, directory: false), initializationAttemptID: initializationAttemptID, reservationAttemptID: reservationAttemptID, reservationIdentity: reservationIdentity)
        return result // Capture in the original cursor before first-sync uncertainty.
    }
    static func bindRoot(_ fd: Int32, root: NativeJournalPairRoot, cloudRootID: UUID, journalBinding: NativeJournalIdentity) throws {
        let expected = try NativeJournalCodec.encode(NativeJournalPairRootBinding(schemaVersion: 1, cloudRootID: cloudRootID, journalBinding: journalBinding, root: root))
        if let existing = try read(fd, "pair-binding.json", limit: 8192) {
            guard existing.identity == root.binding, existing.bytes == expected else { throw NativeEnrollmentJournalError.conflict }
            try syncFile(fd, "pair-binding.json", expected: existing, limit: 8192)
        } else {
            let f = openat(fd, "pair-binding.json.pending", O_RDWR | O_NOFOLLOW | O_NONBLOCK)
            guard f >= 0 else { throw fail() }; defer { close(f) }
            guard try identity(f, directory: false) == root.binding else { throw NativeEnrollmentJournalError.conflict }
            try write(f, bytes: expected); try sync(f)
            guard renameat(fd, "pair-binding.json.pending", fd, "pair-binding.json") == 0 else { throw fail() }
        }
        guard try read(fd, "pair-binding.json", limit: 8192) == NativeJournalNode(identity: root.binding, bytes: expected) else { throw NativeEnrollmentJournalError.conflict }
        try sync(fd)
    }
    static func createCandidates(_ fd: Int32, target: Bool) throws -> NativeJournalPairFiles {
        let h = try create(fd, target ? targetHistory : sourceHistory); defer { close(h) }
        let e = try create(fd, target ? targetEnrollment : sourceEnrollment); defer { close(e) }
        let result = NativeJournalPairFiles(history: try identity(h, directory: false), enrollment: try identity(e, directory: false))
        return result // No payload or synchronization acknowledgment is inferred.
    }
    static func syncCreatedRoot(_ parent: Int32, root: NativeJournalPairRoot, cloudRootID: UUID, journalBinding: NativeJournalIdentity) throws {
        try withRoot(parent, root: root, cloudRootID: cloudRootID, journalBinding: journalBinding, allowEmptyBinding: true) { fd in
            try syncFile(fd, "pair.lock", expected: .init(identity: root.lock, bytes: Data()), limit: 8192)
            try syncFile(fd, "pair-binding.json.pending", expected: .init(identity: root.binding, bytes: Data()), limit: 8192)
            try sync(fd)
        }
        try sync(parent)
    }
    static func syncCreatedCandidates(_ fd: Int32, files: NativeJournalPairFiles, target: Bool) throws {
        try syncFile(fd, target ? targetHistory : sourceHistory, expected: .init(identity: files.history, bytes: Data()), limit: 65536)
        try syncFile(fd, target ? targetEnrollment : sourceEnrollment, expected: .init(identity: files.enrollment, bytes: Data()), limit: 1048576)
        try sync(fd)
    }
    static func current(_ fd: Int32, files: NativeJournalPairFiles?, payload: Payload?) throws {
        let h = try read(fd, historyName, limit: 65536), e = try read(fd, enrollmentName, limit: 1048576)
        if let files, let payload {
            guard h == NativeJournalNode(identity: files.history, bytes: payload.history), e == NativeJournalNode(identity: files.enrollment, bytes: payload.enrollment) else { throw NativeEnrollmentJournalError.conflict }
        } else { guard files == nil, payload == nil, h == nil, e == nil else { throw NativeEnrollmentJournalError.conflict } }
    }
    static func syncFile(_ fd: Int32, _ name: String, expected: NativeJournalNode, limit: Int) throws {
        guard try read(fd, name, limit: limit) == expected else { throw NativeEnrollmentJournalError.conflict }
        let f = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK); guard f >= 0 else { throw fail() }; defer { close(f) }
        guard try identity(f, directory: false) == expected.identity else { throw NativeEnrollmentJournalError.conflict }; try sync(f)
        guard try read(fd, name, limit: limit) == expected else { throw NativeEnrollmentJournalError.conflict }
    }
    /// Recorded candidate ownership permits exact rewrite on its own inode. A
    /// different current inode or a non-prefix candidate payload is never adopted.
    static func publishPair(_ fd: Int32, candidates: NativeJournalPairFiles, target: Bool, payload: Payload, baseline: NativeJournalPairBaseline?, baselinePayload: Payload?) throws {
        let fields = [(historyName, target ? targetHistory : sourceHistory, candidates.history, payload.history, baseline?.files.history, baselinePayload?.history, 65536),
                      (enrollmentName, target ? targetEnrollment : sourceEnrollment, candidates.enrollment, payload.enrollment, baseline?.files.enrollment, baselinePayload?.enrollment, 1048576)]
        for (name, temporary, id, bytes, oldID, oldBytes, limit) in fields {
            let installed = try read(fd, name, limit: limit), pending = try read(fd, temporary, limit: limit)
            if installed?.identity == id {
                guard pending == nil, installed?.bytes == bytes else { throw NativeEnrollmentJournalError.conflict }
                try syncFile(fd, name, expected: .init(identity: id, bytes: bytes), limit: limit)
            } else {
                guard let pending, pending.identity == id, bytes.starts(with: pending.bytes),
                    installed == (oldID.flatMap { old in oldBytes.map { NativeJournalNode(identity: old, bytes: $0) } }) else { throw NativeEnrollmentJournalError.conflict }
                let f = openat(fd, temporary, O_RDWR | O_NOFOLLOW | O_NONBLOCK); guard f >= 0 else { throw fail() }; defer { close(f) }
                guard try identity(f, directory: false) == id else { throw NativeEnrollmentJournalError.conflict }
                try write(f, bytes: bytes); try sync(f)
                guard try read(fd, temporary, limit: limit) == NativeJournalNode(identity: id, bytes: bytes) else { throw NativeEnrollmentJournalError.conflict }
                guard try read(fd, name, limit: limit) == installed else { throw NativeEnrollmentJournalError.conflict }
                guard renameat(fd, temporary, fd, name) == 0 else { throw fail() }; try sync(fd)
                guard try read(fd, name, limit: limit) == NativeJournalNode(identity: id, bytes: bytes) else { throw NativeEnrollmentJournalError.conflict }
            }
        }
        try sync(fd); try current(fd, files: candidates, payload: payload)
    }
}

/// Streamed metadata state: one root declaration and latest exact pair binding,
/// never retained source/target snapshots. Old schema assertions remain metadata.
struct NativePairReplay {
    var lastAssertion: NativeJournalPairAssertion?
    var reservation: NativeJournalPairAssertion?
    var initialization: NativeJournalPairAssertion?
    var initialized = false
    var current: NativeJournalPairAssertion?
    var latest: NativeJournalPairBaseline?
    private var operations = Set<UUID>()
    var retainedOperationIDs: Set<UUID> { operations }
    mutating func newPreparation() { current = nil }
    mutating func accept(_ value: NativeJournalPairAssertion, frame: NativeJournalFrame, attempt: NativeJournalAttempt, previousPhase: Int, previousAttemptID: UUID?, previousIdentity: NativeJournalIdentity?) throws {
        try value.validate()
        guard previousPhase == 2, value.projection.intentAttemptID == frame.intentAttemptID else { throw NativeEnrollmentJournalError.conflict }
        switch value.role {
        case .initReserve:
            guard initialization == nil, current == nil, latest == nil,
                NativeJournalCodec.pairedCompletionReservation <= NativeJournalCodec.pairedReservationLimit else { throw NativeEnrollmentJournalError.capacity }
            guard operations.insert(value.operationID).inserted else { throw NativeEnrollmentJournalError.conflict }
            reservation = value; initialization = value
        case .initBind:
            guard let old = initialization, old.role == .initReserve, value.operationID == old.operationID,
                value.projection == old.projection, value.root?.initializationAttemptID == frame.attemptID,
                value.root?.reservationAttemptID == previousAttemptID, value.root?.reservationIdentity == previousIdentity else { throw NativeEnrollmentJournalError.conflict }
            initialization = value
        case .initComplete:
            guard let old = initialization, old.role == .initBind, same(old, value) else { throw NativeEnrollmentJournalError.conflict }
            initialization = value; initialized = true
        case .sourceReserve:
            guard initialized, current == nil, value.root == initialization?.root, value.baseline == latest else { throw NativeEnrollmentJournalError.conflict }
            let sameInitialization = value.operationID == initialization?.operationID && value.projection == initialization?.projection
            guard sameInitialization || operations.insert(value.operationID).inserted else { throw NativeEnrollmentJournalError.conflict }
            current = value
        case .sourceBind:
            guard let old = current, old.role == .sourceReserve, same(old, value, candidates: false) else { throw NativeEnrollmentJournalError.conflict }
            try distinct(value); current = value
        case .sourceComplete:
            guard let old = current, old.role == .sourceBind, same(old, value), let files = value.candidates else { throw NativeEnrollmentJournalError.conflict }
            current = value; latest = .init(projection: value.projection, files: files, completionAttemptID: frame.attemptID)
        case .targetReserve:
            guard let old = current, old.role == .sourceComplete, value.operationID == old.operationID,
                value.root == old.root, value.projection.intentAttemptID == old.projection.intentAttemptID,
                value.baseline == latest else { throw NativeEnrollmentJournalError.conflict }
            current = value
        case .targetBind:
            guard let old = current, old.role == .targetReserve, same(old, value, candidates: false) else { throw NativeEnrollmentJournalError.conflict }
            try distinct(value); current = value
        case .targetComplete:
            guard let old = current, old.role == .targetBind, same(old, value), let files = value.candidates else { throw NativeEnrollmentJournalError.conflict }
            current = value; latest = .init(projection: value.projection, files: files, completionAttemptID: frame.attemptID)
        }
        lastAssertion = value
    }
    private func same(_ a: NativeJournalPairAssertion, _ b: NativeJournalPairAssertion, candidates: Bool = true) -> Bool {
        a.operationID == b.operationID && a.projection == b.projection && a.root == b.root && a.baseline == b.baseline && (!candidates || a.candidates == b.candidates)
    }
    private func distinct(_ value: NativeJournalPairAssertion) throws {
        guard let root = value.root, let c = value.candidates, c.history != c.enrollment,
            ![root.directory, root.lock, root.binding].contains(c.history), ![root.directory, root.lock, root.binding].contains(c.enrollment),
            value.baseline.map({ old in ![old.files.history, old.files.enrollment].contains(c.history) && ![old.files.history, old.files.enrollment].contains(c.enrollment) }) ?? true else { throw NativeEnrollmentJournalError.conflict }
    }
}

private func nativePairRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    return Darwin.read(fd, buffer, count)
#else
    return Glibc.read(fd, buffer, count)
#endif
}
private func nativePairWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    return Darwin.write(fd, buffer, count)
#else
    return Glibc.write(fd, buffer, count)
#endif
}

extension NativePairFiles {
    static func verifyTransition(_ fd: Int32, candidates: NativeJournalPairFiles, target: Bool, payload: Payload, baseline: NativeJournalPairBaseline?, baselinePayload: Payload?) throws {
        let fields = [(historyName, target ? targetHistory : sourceHistory, candidates.history, payload.history, baseline?.files.history, baselinePayload?.history, 65536),
                      (enrollmentName, target ? targetEnrollment : sourceEnrollment, candidates.enrollment, payload.enrollment, baseline?.files.enrollment, baselinePayload?.enrollment, 1048576)]
        for (name, temporary, id, bytes, oldID, oldBytes, limit) in fields {
            let installed = try read(fd, name, limit: limit), pending = try read(fd, temporary, limit: limit)
            if installed?.identity == id {
                guard pending == nil, installed?.bytes == bytes else { throw NativeEnrollmentJournalError.conflict }
            } else {
                guard let pending, pending.identity == id, bytes.starts(with: pending.bytes),
                    installed == (oldID.flatMap { old in oldBytes.map { NativeJournalNode(identity: old, bytes: $0) } }) else { throw NativeEnrollmentJournalError.conflict }
            }
        }
    }
}
