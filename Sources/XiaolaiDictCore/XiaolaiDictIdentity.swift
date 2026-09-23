/// The signing identifiers the app and its services know each other by, declared once: the app
/// finds each service by its identifier, and each service admits only a caller with the app's.
/// The bundles' Info.plists must say the same — `XiaolaiDictIdentityTests` holds all three to it,
/// and the Makefile holds the built bundle to them.
public enum XiaolaiDictIdentity {
    public static let app = "com.xiaolaidict"
    /// Derived from the app's, so changing that name cannot leave a service behind under the old one.
    public static let dictionaryService = "\(app).DictionaryService"
    /// The local model's service. Its own process, not the dictionary service's: a segfault-prone
    /// private API and a 3–6 GB model in one process would let either take the other down.
    public static let modelService = "\(app).ModelService"
}
