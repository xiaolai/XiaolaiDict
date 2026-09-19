import DictionaryBridge
import Dispatch
import Foundation
import XiaolaiDictCore
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

let listener = try XPCListener(
    service: XiaolaiDictIdentity.dictionaryService,
    targetQueue: lookups,
    requirement: .isFromSameTeam(andMatchesSigningIdentifier: XiaolaiDictIdentity.app)
) { request in
    request.accept { (message: ServiceRequest) -> (any Encodable)? in
        watchdog.run { DictionaryBridge.reply(to: message) }
    }
}
withExtendedLifetime(listener) { dispatchMain() }
