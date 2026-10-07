import Foundation

public enum EraseAction: Sendable, Equatable {
    case preview
    case erase
    case cancel
}

public struct ErasePresentation: Sendable, Equatable {
    public let stage: Stage
    /// An erase is running: the preview stays, and nothing on it can be pressed until it ends.
    public let isErasing: Bool

    public init(stage: Stage = .idle, isErasing: Bool = false) {
        self.stage = stage
        self.isErasing = isErasing
    }

    public enum Stage: Sendable, Equatable {
        case idle
        case previewing(Impact)
        case erased(Report)
        /// The command could not run at all — an unreadable store, a locked file. Distinct from an
        /// erase that ran and left a copy behind, which is `erased` with `backupsLeft`.
        case failed(String)
    }

    public struct Impact: Sendable, Equatable {
        public let lookups: Int
        public let cardsLeftWithoutASentence: Int
        public let backups: Int

        public init(lookups: Int, cardsLeftWithoutASentence: Int, backups: Int) {
            self.lookups = lookups
            self.cardsLeftWithoutASentence = cardsLeftWithoutASentence
            self.backups = backups
        }

        /// Readings, or copies of them this app made: either is something an erase deletes.
        public var hasAnythingToDelete: Bool { lookups > 0 || backups > 0 }
    }

    public struct Report: Sendable, Equatable {
        public let lookupsRemoved: Int
        /// One line per copy that could not be removed, with its reason.
        public let backupsLeft: [String]
        /// What else the erase could not reach, by kind; the section says each.
        public let unreached: [Unreached]

        public init(lookupsRemoved: Int, backupsLeft: [String], unreached: [Unreached]) {
            self.lookupsRemoved = lookupsRemoved
            self.backupsLeft = backupsLeft
            self.unreached = unreached
        }
    }

    /// Something other than a copy that an erase was to reach and could not.
    public enum Unreached: Sendable, Hashable {
        /// The folder the copies live in could not be listed; the system's reason.
        case backupsNotListed(String)
        /// Another connection was reading, so the write-ahead log still holds the erased rows.
        case writeAheadLogBusy
        /// The file could not be rewritten without what was deleted; the system's reason.
        case notRewritten(String)
    }

    /// What an erase could not reach, as a sentence — **said here, in the presentation layer**, for Settings'
    /// erase and the Library's permanent delete alike; the ledger says which, never how.
    public static func reason(for unreached: Unreached) -> String {
        switch unreached {
        case .backupsNotListed(let reason):
            String(localized: "The folder holding its backup copies could not be read, so some may still be there: \(reason)")
        case .writeAheadLogBusy:
            String(localized: "The write-ahead log could not be truncated: another connection is reading it.")
        case .notRewritten(let reason):
            String(localized: """
                The files your reading history is kept in could not be rewritten without what was \
                deleted, so parts of it may remain on disk: \(reason)
                """)
        }
    }

    /// Everything an erase that ran could not reach, a sentence a line — nil when it reached everything.
    public static func shortfall(of report: Report) -> String? {
        let copies = report.backupsLeft.map { line in
            String(localized: "A backup copy could not be deleted: \(line)")
        }
        let sentences = copies + report.unreached.map(reason(for:))
        return sentences.isEmpty ? nil : sentences.joined(separator: "\n")
    }
}
