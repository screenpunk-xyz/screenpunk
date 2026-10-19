import Foundation
import CoreFoundation

/// Manifest-local bounded parser and pinned v1 shape checks from schemas/dashboard-manifest.schema.json.
/// Not a general JSON Schema implementation: semantic oneOf/not constraints are checked by the existing
/// PublicReadProvisioning, EventNavigationEngine and DeviceBehavior validators. No shared/exported parser.
enum DevicePackageManifestPreflight {
    static func decode(_ bytes: Data) throws -> DashboardManifest {
        guard bytes.count <= DevicePackageQualifier.manifestLimit else { throw DevicePackageQualificationError.sizeLimit }
        guard String(data: bytes, encoding: .utf8) != nil else { throw DevicePackageQualificationError.invalidManifest }
        try bytes.withUnsafeBytes { raw in
            var scanner = Scanner(bytes: raw.bindMemory(to: UInt8.self), remaining: 65_536)
            try scanner.value(depth: 0); scanner.space()
            guard scanner.index == scanner.bytes.count else { throw DevicePackageQualificationError.invalidManifest }
        }
        let value = try JSONSerialization.jsonObject(with: bytes)
        try shape(value, .manifest)
        return try JSONDecoder().decode(DashboardManifest.self, from: bytes)
    }
    private enum Shape { case manifest, target, safeArea, connections, connection, cameraEntities, serviceCalls, serviceCall, entityIDs, operations, operation, publicHTTP, publicOperations, publicOperation, publicParameters, publicParameter, parameterValues, pathSegment, files, file, pages, page, eventRules, eventRule, eventSource, eventParameters, filter, filterFields, condition, conditionFields, defaults, allowedPageIDs, allowedReturnBehaviors, payload, payloadPageID, payloadReturnBehavior, payloadTimeout, payloadEventID, payloadCorrelationID, payloadOccurredAt, deviceBehavior, temporaryActivation, audio }
    private static func shape(_ value: Any, _ type: Shape) throws {
        switch type {
        case .manifest:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 14 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["schemaVersion","dashboardId","name","revision","entrypoint","sdkVersion","digest","target","connections","files","pages","defaultPageId","eventRules","deviceBehavior"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["schemaVersion","dashboardId","name","revision","entrypoint","sdkVersion","target","connections","files"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["schemaVersion"] { try number(item, integer: true, minimum: -1.7976931348623157e+308, maximum: 1.7976931348623157e+308, exclusiveMinimum: false); guard (item as? NSNumber)?.doubleValue == 1 else { throw DevicePackageQualificationError.invalidManifest } }
            if let item = map["dashboardId"] { try string(item, minimum: 0, maximum: 2097152) }
            if let item = map["name"] { try string(item, minimum: 1, maximum: 128) }
            if let item = map["revision"] { try string(item, minimum: 0, maximum: 2097152) }
            if let item = map["entrypoint"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^(?!/)(?!.*\\.\\.)[A-Za-z0-9._/-]+\\.html$") }
            if let item = map["sdkVersion"] { try string(item, minimum: 0, maximum: 2097152, values: ["1"]) }
            if let item = map["digest"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^[a-f0-9]{64}$") }
            if let item = map["target"] { try shape(item, .target) }
            if let item = map["connections"] { try shape(item, .connections) }
            if let item = map["files"] { try shape(item, .files) }
            if let item = map["pages"] { try shape(item, .pages) }
            if let item = map["defaultPageId"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^[A-Za-z0-9_-]{1,128}$") }
            if let item = map["eventRules"] { try shape(item, .eventRules) }
            if let item = map["deviceBehavior"] { try shape(item, .deviceBehavior) }
        case .target:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 6 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["profileId","width","height","scale","orientation","safeArea"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["profileId","width","height","scale","orientation"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["profileId"] { try string(item, minimum: 1, maximum: 128) }
            if let item = map["width"] { try number(item, integer: true, minimum: 1, maximum: 10000, exclusiveMinimum: false) }
            if let item = map["height"] { try number(item, integer: true, minimum: 1, maximum: 10000, exclusiveMinimum: false) }
            if let item = map["scale"] { try number(item, integer: false, minimum: 0, maximum: 8, exclusiveMinimum: true) }
            if let item = map["orientation"] { try string(item, minimum: 0, maximum: 2097152, values: ["portrait","landscape"]) }
            if let item = map["safeArea"] { try shape(item, .safeArea) }
        case .safeArea:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 4 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["top","right","bottom","left"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["top","right","bottom","left"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["top"] { try number(item, integer: false, minimum: 0, maximum: 1.7976931348623157e+308, exclusiveMinimum: false) }
            if let item = map["right"] { try number(item, integer: false, minimum: 0, maximum: 1.7976931348623157e+308, exclusiveMinimum: false) }
            if let item = map["bottom"] { try number(item, integer: false, minimum: 0, maximum: 1.7976931348623157e+308, exclusiveMinimum: false) }
            if let item = map["left"] { try number(item, integer: false, minimum: 0, maximum: 1.7976931348623157e+308, exclusiveMinimum: false) }
        case .connections:
            guard let items = value as? [Any], (0...64).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try shape(item, .connection) }
        case .connection:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 6 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["alias","required","cameraEntities","serviceCalls","operations","publicHTTP"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["alias","required"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["alias"] { try string(item, minimum: 1, maximum: 64, pattern: "^[A-Za-z][A-Za-z0-9_-]*$") }
            if let item = map["required"] { guard let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw DevicePackageQualificationError.invalidManifest } }
            if let item = map["cameraEntities"] { try shape(item, .cameraEntities) }
            if let item = map["serviceCalls"] { try shape(item, .serviceCalls) }
            if let item = map["operations"] { try shape(item, .operations) }
            if let item = map["publicHTTP"] { try shape(item, .publicHTTP) }
        case .cameraEntities:
            guard let items = value as? [Any], (0...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 0, maximum: 255, pattern: "^camera\\.[a-z0-9_]+$") }
            guard Set(items.map { String(describing: $0) }).count == items.count else { throw DevicePackageQualificationError.invalidManifest }
        case .serviceCalls:
            guard let items = value as? [Any], (0...128).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try shape(item, .serviceCall) }
        case .serviceCall:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 4 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["domain","service","entityIds","allowUntargeted"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["domain","service","entityIds"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["domain"] { try string(item, minimum: 1, maximum: 128, pattern: "^[a-z0-9_]+$") }
            if let item = map["service"] { try string(item, minimum: 1, maximum: 128, pattern: "^[a-z0-9_]+$") }
            if let item = map["entityIds"] { try shape(item, .entityIDs) }
            if let item = map["allowUntargeted"] { guard let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw DevicePackageQualificationError.invalidManifest } }
        case .entityIDs:
            guard let items = value as? [Any], (0...128).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 0, maximum: 255, pattern: "^[a-z0-9_]+\\.[a-z0-9_]+$") }
            guard Set(items.map { String(describing: $0) }).count == items.count else { throw DevicePackageQualificationError.invalidManifest }
        case .operations:
            guard let items = value as? [Any], (0...32).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try shape(item, .operation) }
        case .operation:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 3 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["name","kind","maxAgeSeconds"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["name","kind"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["name"] { try string(item, minimum: 1, maximum: 64, pattern: "^[A-Za-z][A-Za-z0-9_-]*$") }
            if let item = map["kind"] { try string(item, minimum: 0, maximum: 2097152, values: ["http","ws"]) }
            if let item = map["maxAgeSeconds"] { try number(item, integer: true, minimum: 1, maximum: 1.7976931348623157e+308, exclusiveMinimum: false) }
        case .publicHTTP:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 3 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["origin","userAgent","operations"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["origin","userAgent","operations"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["origin"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^https://[a-z0-9]+(?:[.-][a-z0-9]+)*(?::443)?$") }
            if let item = map["userAgent"] { try string(item, minimum: 1, maximum: 256, pattern: "^[\\x20-\\x7e]+$") }
            if let item = map["operations"] { try shape(item, .publicOperations) }
        case .publicOperations:
            guard let items = value as? [Any], (1...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try shape(item, .publicOperation) }
        case .publicOperation:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 6 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["name","path","response","parameters","maxAgeSeconds","staleSeconds"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["name","path","response","parameters","maxAgeSeconds","staleSeconds"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["name"] { try string(item, minimum: 1, maximum: 128, pattern: "^[a-zA-Z0-9_.-]+$") }
            if let item = map["path"] { try string(item, minimum: 1, maximum: 512) }
            if let item = map["response"] { try string(item, minimum: 0, maximum: 2097152, values: ["json","raster"]) }
            if let item = map["parameters"] { try shape(item, .publicParameters) }
            if let item = map["maxAgeSeconds"] { try number(item, integer: true, minimum: 1, maximum: 86400, exclusiveMinimum: false) }
            if let item = map["staleSeconds"] { try number(item, integer: true, minimum: 0, maximum: 604800, exclusiveMinimum: false) }
        case .publicParameters:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 12 else { throw DevicePackageQualificationError.invalidManifest }
            for item in map.values { try shape(item, .publicParameter) }
        case .publicParameter:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 5 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["location","minimum","maximum","values","pathSegment"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["location"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["location"] { try string(item, minimum: 0, maximum: 2097152, values: ["path","query"]) }
            if let item = map["minimum"] { try number(item, integer: true, minimum: -9007199254740991, maximum: 9007199254740991, exclusiveMinimum: false) }
            if let item = map["maximum"] { try number(item, integer: true, minimum: -9007199254740991, maximum: 9007199254740991, exclusiveMinimum: false) }
            if let item = map["values"] { try shape(item, .parameterValues) }
            if let item = map["pathSegment"] { try shape(item, .pathSegment) }
        case .parameterValues:
            guard let items = value as? [Any], (1...64).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 1, maximum: 256, pattern: "^[\\x20-\\x7e]+$") }
            guard Set(items.map { String(describing: $0) }).count == items.count else { throw DevicePackageQualificationError.invalidManifest }
        case .pathSegment:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 1 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["maxLength"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["maxLength"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["maxLength"] { try number(item, integer: true, minimum: 1, maximum: 256, exclusiveMinimum: false) }
        case .files:
            guard let items = value as? [Any], (1...2000).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try shape(item, .file) }
        case .file:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 3 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["path","bytes","sha256"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["path","bytes","sha256"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["path"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^(?!/)(?!.*\\.\\.)[A-Za-z0-9._/-]+$") }
            if let item = map["bytes"] { try number(item, integer: true, minimum: 1, maximum: 52428800, exclusiveMinimum: false) }
            if let item = map["sha256"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^[a-f0-9]{64}$") }
        case .pages:
            guard let items = value as? [Any], (1...64).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try shape(item, .page) }
        case .page:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 3 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["id","name","path"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["id","name","path"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["id"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^[A-Za-z0-9_-]{1,128}$") }
            if let item = map["name"] { try string(item, minimum: 1, maximum: 128) }
            if let item = map["path"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^(?!/)(?!.*\\.\\.)[A-Za-z0-9._/-]+\\.html$") }
        case .eventRules:
            guard let items = value as? [Any], (0...64).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try shape(item, .eventRule) }
        case .eventRule:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 12 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["id","name","source","filter","condition","defaults","priority","userConfigurable","allowedPageIds","allowedReturnBehaviors","allowTimeoutOverride","payload"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["id","name","source","defaults","priority","userConfigurable","allowedPageIds","allowedReturnBehaviors","allowTimeoutOverride"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["id"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^[A-Za-z0-9_-]{1,128}$") }
            if let item = map["name"] { try string(item, minimum: 1, maximum: 128) }
            if let item = map["source"] { try shape(item, .eventSource) }
            if let item = map["filter"] { try shape(item, .filter) }
            if let item = map["condition"] { try shape(item, .condition) }
            if let item = map["defaults"] { try shape(item, .defaults) }
            if let item = map["priority"] { try number(item, integer: true, minimum: -100, maximum: 100, exclusiveMinimum: false) }
            if let item = map["userConfigurable"] { guard let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw DevicePackageQualificationError.invalidManifest } }
            if let item = map["allowedPageIds"] { try shape(item, .allowedPageIDs) }
            if let item = map["allowedReturnBehaviors"] { try shape(item, .allowedReturnBehaviors) }
            if let item = map["allowTimeoutOverride"] { guard let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw DevicePackageQualificationError.invalidManifest } }
            if let item = map["payload"] { try shape(item, .payload) }
        case .eventSource:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 7 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["mode","alias","operation","parameters","pollIntervalSeconds","refreshOperation","refreshAlias"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["mode","alias","operation","parameters"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["mode"] { try string(item, minimum: 0, maximum: 2097152, values: ["live","poll"]) }
            if let item = map["alias"] { try string(item, minimum: 1, maximum: 128) }
            if let item = map["operation"] { try string(item, minimum: 1, maximum: 128) }
            if let item = map["parameters"] { try shape(item, .eventParameters) }
            if let item = map["pollIntervalSeconds"] { try number(item, integer: true, minimum: 15, maximum: 86400, exclusiveMinimum: false) }
            if let item = map["refreshOperation"] { try string(item, minimum: 1, maximum: 128) }
            if let item = map["refreshAlias"] { try string(item, minimum: 1, maximum: 64) }
        case .eventParameters:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 32 else { throw DevicePackageQualificationError.invalidManifest }
            for item in map.values { try scalar(item) }
        case .filter:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 2 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["field","equals"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["field","equals"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["field"] { try shape(item, .filterFields) }
            if let item = map["equals"] { try scalar(item) }
        case .filterFields:
            guard let items = value as? [Any], (1...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 1, maximum: 128) }
        case .condition:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 2 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["field","equals"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["field","equals"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["field"] { try shape(item, .conditionFields) }
            if let item = map["equals"] { try scalar(item) }
        case .conditionFields:
            guard let items = value as? [Any], (1...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 1, maximum: 128) }
        case .defaults:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 5 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["enabled","pageId","returnBehavior","timeoutSeconds","allowPayloadOverrides"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["enabled","pageId","returnBehavior","timeoutSeconds","allowPayloadOverrides"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["enabled"] { guard let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw DevicePackageQualificationError.invalidManifest } }
            if let item = map["pageId"] { try string(item, minimum: 0, maximum: 2097152, pattern: "^[A-Za-z0-9_-]{1,128}$") }
            if let item = map["returnBehavior"] { try string(item, minimum: 0, maximum: 2097152, values: ["stay","timeout","conditionClear"]) }
            if let item = map["timeoutSeconds"] { try number(item, integer: true, minimum: 1, maximum: 3600, exclusiveMinimum: false) }
            if let item = map["allowPayloadOverrides"] { guard let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw DevicePackageQualificationError.invalidManifest } }
        case .allowedPageIDs:
            guard let items = value as? [Any], (0...64).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 0, maximum: 2097152, pattern: "^[A-Za-z0-9_-]{1,128}$") }
            guard Set(items.map { String(describing: $0) }).count == items.count else { throw DevicePackageQualificationError.invalidManifest }
        case .allowedReturnBehaviors:
            guard let items = value as? [Any], (0...3).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 0, maximum: 2097152, values: ["stay","timeout","conditionClear"]) }
            guard Set(items.map { String(describing: $0) }).count == items.count else { throw DevicePackageQualificationError.invalidManifest }
        case .payload:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 6 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["pageId","returnBehavior","timeoutSeconds","eventId","correlationId","occurredAt"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["pageId"] { try shape(item, .payloadPageID) }
            if let item = map["returnBehavior"] { try shape(item, .payloadReturnBehavior) }
            if let item = map["timeoutSeconds"] { try shape(item, .payloadTimeout) }
            if let item = map["eventId"] { try shape(item, .payloadEventID) }
            if let item = map["correlationId"] { try shape(item, .payloadCorrelationID) }
            if let item = map["occurredAt"] { try shape(item, .payloadOccurredAt) }
        case .payloadPageID:
            guard let items = value as? [Any], (1...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 1, maximum: 128) }
        case .payloadReturnBehavior:
            guard let items = value as? [Any], (1...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 1, maximum: 128) }
        case .payloadTimeout:
            guard let items = value as? [Any], (1...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 1, maximum: 128) }
        case .payloadEventID:
            guard let items = value as? [Any], (1...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 1, maximum: 128) }
        case .payloadCorrelationID:
            guard let items = value as? [Any], (1...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 1, maximum: 128) }
        case .payloadOccurredAt:
            guard let items = value as? [Any], (1...16).contains(items.count) else { throw DevicePackageQualificationError.invalidManifest }
            for item in items { try string(item, minimum: 1, maximum: 128) }
        case .deviceBehavior:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 2 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["temporaryActivation","audio"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["temporaryActivation"] { try shape(item, .temporaryActivation) }
            if let item = map["audio"] { try shape(item, .audio) }
        case .temporaryActivation:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 8 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["source","entityId","activeState","inactiveState","idAttribute","startedAtAttribute","expiresAtAttribute","maxDurationSeconds"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["source","entityId","activeState","inactiveState","idAttribute","startedAtAttribute","expiresAtAttribute","maxDurationSeconds"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["source"] { try string(item, minimum: 0, maximum: 2097152, values: ["homeAssistant"]) }
            if let item = map["entityId"] { try string(item, minimum: 0, maximum: 255, pattern: "^[a-z0-9_]+\\.[a-z0-9_]+$(?![\\s\\S])") }
            if let item = map["activeState"] { try string(item, minimum: 1, maximum: 128, pattern: "^[^\\u0000-\\u001f\\u007f-\\u009f]+$(?![\\s\\S])") }
            if let item = map["inactiveState"] { try string(item, minimum: 1, maximum: 128, pattern: "^[^\\u0000-\\u001f\\u007f-\\u009f]+$(?![\\s\\S])") }
            if let item = map["idAttribute"] { try string(item, minimum: 1, maximum: 128, pattern: "^[A-Za-z0-9_]+$(?![\\s\\S])") }
            if let item = map["startedAtAttribute"] { try string(item, minimum: 1, maximum: 128, pattern: "^[A-Za-z0-9_]+$(?![\\s\\S])") }
            if let item = map["expiresAtAttribute"] { try string(item, minimum: 1, maximum: 128, pattern: "^[A-Za-z0-9_]+$(?![\\s\\S])") }
            if let item = map["maxDurationSeconds"] { try number(item, integer: true, minimum: 1, maximum: 3600, exclusiveMinimum: false) }
        case .audio:
            guard let map = value as? [String: Any] else { throw DevicePackageQualificationError.invalidManifest }
            guard map.count <= 1 else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(map.keys).isSubset(of: Set(["autoplay"] as [String])) else { throw DevicePackageQualificationError.invalidManifest }
            guard Set(["autoplay"] as [String]).isSubset(of: Set(map.keys)) else { throw DevicePackageQualificationError.invalidManifest }
            if let item = map["autoplay"] { guard let number = item as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw DevicePackageQualificationError.invalidManifest } }
        }
    }
    private static func string(_ value: Any, minimum: Int, maximum: Int, pattern: String? = nil, values: Set<String>? = nil) throws {
        guard let text = value as? String, (minimum...maximum).contains(text.unicodeScalars.count),
              values.map({ $0.contains(text) }) ?? true else { throw DevicePackageQualificationError.invalidManifest }
        if let pattern {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression.firstMatch(in: text, range: range), match.range == range else { throw DevicePackageQualificationError.invalidManifest }
        }
    }
    private static func number(_ value: Any, integer: Bool, minimum: Double, maximum: Double, exclusiveMinimum: Bool) throws {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw DevicePackageQualificationError.invalidManifest }
        let value = number.doubleValue
        guard value.isFinite, value >= minimum, value <= maximum, !exclusiveMinimum || value > minimum,
              !integer || value.rounded(.towardZero) == value else { throw DevicePackageQualificationError.invalidManifest }
    }
    private static func scalar(_ value: Any) throws {
        guard value is String || value is NSNull || (value is NSNumber && (value as! NSNumber).doubleValue.isFinite) else { throw DevicePackageQualificationError.invalidManifest }
    }
    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>; var remaining: Int; var index = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func require(_ byte: UInt8) throws { guard index < bytes.count, bytes[index] == byte else { throw DevicePackageQualificationError.invalidManifest }; index += 1 }
        mutating func value(depth: Int) throws {
            space(); remaining -= 1
            guard depth <= 32, remaining >= 0, index < bytes.count else { throw DevicePackageQualificationError.invalidManifest }
            switch bytes[index] {
            case 123:
                index += 1; space(); var keys = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string(); guard keys.insert(key).inserted else { throw DevicePackageQualificationError.invalidManifest }
                    space(); try require(58); try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 125 { index += 1; return }
                    try require(44); space()
                }
            case 91:
                index += 1; space()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 93 { index += 1; return }
                    try require(44)
                }
            case 34: _ = try string()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            default:
                let start = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                guard text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw DevicePackageQualificationError.invalidManifest }
            }
        }
        mutating func literal(_ value: String) throws { for byte in value.utf8 { try require(byte) } }
        mutating func hex() throws -> UInt16 {
            var result: UInt16 = 0
            for _ in 0..<4 {
                guard index < bytes.count else { throw DevicePackageQualificationError.invalidManifest }
                let byte = bytes[index]; index += 1
                let value: UInt16
                switch byte { case 48...57: value = UInt16(byte-48); case 65...70: value = UInt16(byte-55); case 97...102: value = UInt16(byte-87); default: throw DevicePackageQualificationError.invalidManifest }
                result = result * 16 + value
            }
            return result
        }
        mutating func string() throws -> String {
            let start = index; try require(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                guard byte >= 32 else { throw DevicePackageQualificationError.invalidManifest }
                if byte == 92 {
                    guard index < bytes.count else { throw DevicePackageQualificationError.invalidManifest }
                    let escape = bytes[index]; index += 1
                    if escape == 117 {
                        let scalar = try hex()
                        if (0xD800...0xDBFF).contains(scalar) {
                            try require(92); try require(117); let low = try hex()
                            guard (0xDC00...0xDFFF).contains(low) else { throw DevicePackageQualificationError.invalidManifest }
                        } else if (0xDC00...0xDFFF).contains(scalar) { throw DevicePackageQualificationError.invalidManifest }
                    } else if ![34,92,47,98,102,110,114,116].contains(escape) { throw DevicePackageQualificationError.invalidManifest }
                }
            }
            throw DevicePackageQualificationError.invalidManifest
        }
    }
}
