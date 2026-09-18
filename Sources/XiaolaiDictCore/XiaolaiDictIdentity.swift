/// The signing identifiers the app and its dictionary service know each other by, declared once:
/// the app finds the service by its identifier, and the service admits only a caller with the
/// app's. The bundles' Info.plists must say the same — `XiaolaiDictIdentityTests` holds them to it, and
/// the Makefile holds the built bundle to both.
public enum XiaolaiDictIdentity {
    public static let app = "com.xiaolaidict"
    public static let dictionaryService = "com.xiaolaidict.DictionaryService"
}
