import DictionaryBridge
import DictionaryModel
import Dispatch
import Foundation
import PhraseLookup
import XiaolaiDictBase
import os
import XPC

// The only process that calls the private DictionaryServices API (design note §10). If a macOS
// update makes it segfault, this process dies, launchd restarts it on the next request, and XiaolaiDict
// shows the public API's plain-text definition meanwhile.
//
// Only XiaolaiDict may connect: the same team and XiaolaiDict's own signing identifier. Without that, any
// process that found this service could drive a private API through it.

let log = Logger(subsystem: XiaolaiDictIdentity.dictionaryService, category: "lookup")

// One request at a time. The listener's default queue may be concurrent, and nothing documents the
// private API as safe to enter twice at once; `DictionaryBridge` serializes too, but requests
// should not even wait on each other's threads.
let lookups = DispatchQueue(label: "\(XiaolaiDictIdentity.dictionaryService).lookups")

// A deadlock in the private API cannot be interrupted, and a stuck service would make every later
// request queue behind it and time out in the app. Past this limit — well beyond the app's own 3 s
// deadline, and hundreds of times a normal lookup — the process exits, and launchd starts a clean
// one on the next request.
let watchdog = Watchdog(limit: .seconds(5)) {
    log.fault("a lookup has been stuck for 5 s; exiting so launchd starts a fresh service")
    exit(EX_SOFTWARE)
}

// The phrase a reader did not know to look up — the failure this app can uniquely catch. Read **off the
// reply path**, and scoped to the dictionaries this reader studies from rather than to every one that
// happens to index English: `serves(reader:)` admits 5 here where the wider predicate admitted 34.
//
// The first read walks each body once — about 7 s for NOAD — and stores the result, so every launch after
// that is a file read. Until it is ready a lookup answers `.notReady`, a different fact from "no phrase
// here" and said as one.
//
// Not on `lookups`: that queue answers requests, and the first request must not be stuck behind this.
let phrases = PhraseReader.forReader(ReaderLanguage.preferred) { why in
    // Not a fault: no index is the ordinary state for a reader who has not built one, and the phrase
    // feature works without it. Logged so "my idioms are missing" has an answer.
    log.notice("phrases: \(why, privacy: .public)")
}
// **The lemma table, read the same way and for the same reason**: what a reader's own dictionaries print as
// inflections, which `NLTagger` answers nothing for or answers wrongly (ADR-0051). The stored one is put in force first,
// off the reply path, so a lookup that arrives meanwhile answers with the tagger alone; the dictionaries are read only where it
// is stale, and the app — a different process — finds the file when it next asks.
DispatchQueue.global(qos: .utility).async {
    FormAuthority.shared.use(FormTableStore())
    let forms = FormTableReader.read { why in log.notice("forms: \(why, privacy: .public)") }
    if let table = forms.table { FormAuthority.shared.publish(table) }
    // **Counted, not assumed**: a table that judges nothing looks like a reader whose words are all the
    // tagger's, so the numbers are how the two are told apart afterwards.
    log.notice("""
        forms: \(forms.table?.count ?? 0, privacy: .public) from \(forms.read.count, privacy: .public) \
        dictionaries, \(forms.failed.count, privacy: .public) unread, \
        \(forms.wasCurrent ? "stored" : "rebuilt", privacy: .public)
        """)
    for name in forms.failed { log.error("forms: could not read \(name, privacy: .public)") }
}
DispatchQueue.global(qos: .utility).async {
    let reading = phrases.read()
    // **Counted, not assumed.** A detector over an empty inventory finds nothing and looks exactly like a
    // reader standing on ordinary words, so the numbers are the only way to tell the two apart afterwards.
    log.notice("""
        phrases: \(reading.phrases, privacy: .public) from \(reading.read.count, privacy: .public) \
        dictionaries, \(reading.failed.count, privacy: .public) unread
        """)
    for name in reading.failed { log.error("phrases: could not read \(name, privacy: .public)") }
}

let listener = try XPCListener(
    service: XiaolaiDictIdentity.dictionaryService,
    targetQueue: lookups,
    requirement: .isFromSameTeam(andMatchesSigningIdentifier: XiaolaiDictIdentity.app)
) { request in
    request.accept { (message: ServiceRequest) -> (any Encodable)? in
        watchdog.run {
            DictionaryBridge.reply(to: message, phrases: phrases) { word, phrase in
                // **Two stages, logged apart**, so whether the phrase delays the word is a number read
                // from real lookups rather than a guess — the measurement the split decision waits on.
                // `notice`, not `info`: info is not kept by default, and these are read back later.
                log.notice("timing: word \(Int(word.milliseconds), privacy: .public) ms · phrase \(Int(phrase.milliseconds), privacy: .public) ms")
            }
        }
    }
}
withExtendedLifetime(listener) { dispatchMain() }
