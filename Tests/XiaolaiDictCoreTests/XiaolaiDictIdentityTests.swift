import Foundation
import XiaolaiDictBase
import XiaolaiDictCore
import Testing

/// The app finds its services, and each service admits the app, by identifiers compiled into both —
/// and the bundles declare theirs in Info.plist. A mismatch builds and signs cleanly, then fails
/// every lookup at run time; it is caught here instead.
struct XiaolaiDictIdentityTests {
    private func bundleIdentifier(in plist: String) throws -> String? {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/\(plist)")
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return (object as? [String: Any])?["CFBundleIdentifier"] as? String
    }

    @Test func theAppsPlistDeclaresTheAppsIdentifier() throws {
        #expect(try bundleIdentifier(in: "Info.plist") == XiaolaiDictIdentity.app)
    }

    @Test func theServicesPlistDeclaresTheServicesIdentifier() throws {
        #expect(try bundleIdentifier(in: "DictionaryService-Info.plist") == XiaolaiDictIdentity.dictionaryService)
    }

    @Test func theModelServicesPlistDeclaresItsIdentifier() throws {
        #expect(try bundleIdentifier(in: "ModelService-Info.plist") == XiaolaiDictIdentity.modelService)
    }
}
