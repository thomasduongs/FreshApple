import Foundation
import SideSign

/// Names are persisted before requests so a lost response can be reconciled next time.
enum ProfileRenewal {
    static func newName() -> String { "FreshApple " + UUID().uuidString }

    static func renew<Value>(name: String, profileIDs: [String],
                             saveName: (String) throws -> Void,
                             update: (String, String) async throws -> Value,
                             create: (String) async throws -> Value) async throws -> Value {
        let ids = Set(profileIDs)
        var currentName = name
        if ids.count > 1 {
            currentName = newName()
            try saveName(currentName)
        }
        do {
            if ids.count == 1, let id = ids.first {
                return try await update(id, currentName)
            }
            return try await create(currentName)
        } catch ServerError.underlyingError(code: 35, message: _) {
            // Apple may have a duplicate omitted from the list. Recover once, without deletion.
            let replacement = newName()
            try saveName(replacement)
            return try await create(replacement)
        }
    }
}
