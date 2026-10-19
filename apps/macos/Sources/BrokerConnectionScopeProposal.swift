import Foundation
import ScreenpunkCore

/// Builds only the nonsecret editable scope. The credential reference remains
/// blank for connection.update; a stand-in exists solely during local syntax
/// validation because the core grant validator expects a stored reference.
enum BrokerConnectionScopeProposal {
    enum Failure: Error { case invalidEdit }

    static func prepare(grant draft: ConnectionGrant, alias: String,
                        paths: [String], enabled: [Bool]) throws -> ConnectionGrant {
        guard draft.authRef.isEmpty,
              paths.count == draft.operations.count,
              enabled.count == paths.count else { throw Failure.invalidEdit }
        var proposed = draft
        proposed.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        proposed.operations = draft.operations.enumerated().compactMap { index, original in
            guard enabled[index] else { return nil }
            var operation = original
            operation.path = paths[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return operation
        }
        guard !proposed.operations.isEmpty, proposed != draft else { throw Failure.invalidEdit }
        var validated = proposed
        validated.authRef = "scope-edit-validation"
        do { try ConnectionGrantValidator.validate(validated) }
        catch { throw Failure.invalidEdit }
        return proposed
    }
}
