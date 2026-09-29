import Foundation

/// Which language the reader reads, for deciding which dictionaries serve them.
///
/// **In `DictionaryModel` because the app's targets all link it and `XiaolaiDictCore` is not.** It lived in
/// `XiaolaiDictCore`, which the dictionary service does not link — so the service could not ask which
/// language its reader reads, and the phrase inventory was about to spell it a third time. Three spellings of
/// one question is how the answers drift.
///
/// **`XiaolaiDictIndex` still spells it inline, and that is deliberate.** It links `AppleDictionaryFormat`
/// alone; pulling this module in for one accessor would widen an instrument's dependencies to narrow a
/// duplication. Two spellings, one of which is a command's default flag value.
public enum ReaderLanguage {
    /// The first entry of `Locale.preferredLanguages`.
    ///
    /// **Not `Locale.current`.** The two agreed when measured on 2026-09-22 — forced Chinese-first,
    /// `Locale.current.identifier` answered `zh_CN` — but that probe ran in a bare binary whose
    /// `Bundle.main.localizations` is empty, and the shipping bundle carries `en` alone. Whether
    /// Foundation resolves the app's locale against its available localizations in *that* shape was
    /// never established, and `preferredLanguages` cannot be wrong either way: it is the system's
    /// list, not a negotiation with the bundle.
    ///
    /// Empty only on a system with no language list at all, which is not a state a Mac reaches.
    public static var preferred: String { Locale.preferredLanguages.first ?? "en" }
}
