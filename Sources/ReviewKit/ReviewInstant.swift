import Foundation

/// **The instant a review is scheduled with is the instant that is stored.**
///
/// `Date` keeps seconds since 2001 as a `Double`; the ledger keeps seconds since 1970. Encoding adds
/// the 978,307,200 seconds between the two and decoding subtracts them, and the addition rounds: for
/// 2018–2035 dates it drops a fractional bit, so about half of present-day instants read back an ulp
/// away from the one that was written. Decoding a stored value and encoding it again changes
/// nothing, so `stored` — encode, then decode — is idempotent and never changes what a column holds.
///
/// It matters because elapsed days are floored. A grade scheduled with the in-memory instant can
/// fall a day short — 86,399.99999988 s — of the instant it is stored as, exactly 86,400 s, and the
/// scheduler's short-term and long-term branches then disagree: S 10.96 against S 13.47 for the
/// same card. The ledger's own history would replay to a state the ledger does not hold. So whoever
/// schedules a review canonicalises the instant first, and every encoding and decoding of a review
/// instant goes through here: one spelling, so the scheduled instant **is** the replayed one.
///
/// Foundation only and no conditional compilation, so it can move to `ReviewKit` unchanged.
public enum ReviewInstant {
    /// The value a ledger column holds for `instant`: seconds since 1970.
    public static func encoded(_ instant: Date) -> Double { instant.timeIntervalSince1970 }

    /// The instant a ledger column's value stands for.
    public static func decoded(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }

    /// `instant` as every later reader of the ledger will see it — a replay, another device, this
    /// ledger tomorrow.
    public static func stored(_ instant: Date) -> Date { decoded(encoded(instant)) }
}
