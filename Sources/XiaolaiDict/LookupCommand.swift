import Foundation
import XiaolaiDictCore

/// How the command-line modes exit. From `<sysexits.h>` where one fits.
enum CommandStatus: Int32 {
    /// Every lookup was answered with entries by the dictionary service; a selection was read.
    case success = 0
    /// A lookup fell back or found nothing; nothing was selected; the app was not running.
    case failure = 1
    /// EX_USAGE: the command line was wrong.
    case usage = 64
    /// EX_SOFTWARE: XiaolaiDict itself failed — a report could not be encoded.
    case internalError = 70
    /// Stopped before finishing.
    case interrupted = 130
}

/// `XiaolaiDict --lookup TERM`: lookups through the real XPC path, one JSON object per line on stdout
/// (JSON Lines). The verification hook for the part no unit test can reach — whether the bundled
/// service is found, accepts this app's signature, and answers. Only meaningful inside the built
/// bundle, where the service lives.
enum LookupCommand {
    /// `repeats` lookups on one client, `interval` apart — how a crashed service's fallback and
    /// relaunch are verified: kill the service between two of them.
    ///
    /// Exits `.success` only if every lookup was answered with entries by the service. A fallback in
    /// the middle of a run is what a repeat run exists to catch, so it is not hidden behind a
    /// success at the end.
    /// Everything outside the lookups is injected — the clock, the pause between lookups, and both
    /// outputs — so timing, repeats, exit status and error output are testable without the service.
    static func run(
        term: String, repeats: Int, interval: Duration,
        lookup: @Sendable (String) async throws(CancellationError) -> LookupOutcome,
        now: @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        write: @Sendable (String) -> Void = writeLine,
        writeError: @Sendable (String) -> Void = writeError
    ) async -> CommandStatus {
        let start = now()
        var status = CommandStatus.success
        for index in 0..<repeats {
            do {
                if index > 0 { try await sleep(interval) }
                let began = now()
                let outcome = try await lookup(term)
                let report = LookupReport(term: term, outcome: outcome, startedAt: began - start, took: now() - began)
                write(try jsonLine(report))
                if case .entries = outcome {} else { status = .failure }
            } catch is CancellationError {
                return .interrupted
            } catch {
                writeError("could not encode the report: \(error)")
                return .internalError
            }
        }
        return status
    }

    /// `XiaolaiDict --read-point X Y`: the word under a screen point, through the hover paths — the
    /// three Accessibility dialects, then the recogniser. Reports which path answered and what it
    /// cost, so the dialects can be verified on a real app without moving anyone's pointer.
    ///
    /// The modifier gate is bypassed here on purpose: this is the instrument, and a probe that
    /// needed a key held could not be driven over SSH.
    @MainActor
    static func readPoint(x: Double, y: Double) async -> CommandStatus {
        let started = ContinuousClock.now
        let reader = HoverReader(policy: { .shipped })
        let outcome = await reader.read(
            at: CGPoint(x: x, y: y), modifiersHeld: [HoverPolicy.shipped.modifier],
            pointerStillFor: .seconds(1))
        let took = (ContinuousClock.now - started).milliseconds
        switch outcome {
        case .selection(let selection):
            do {
                writeLine(try jsonLine(PointReport(selection, milliseconds: took.rounded())))
                return .success
            } catch {
                writeError("could not encode the report: \(error)")
                return .internalError
            }
        case .quiet(let refusal):
            writeError("nothing read: \(refusal.reason)")
            return .failure
        case .nothing(let why):
            writeError("nothing read: \(why)")
            return .failure
        }
    }

    /// `XiaolaiDict --read-selection BUNDLE_ID`: what the reader would see from that app's selection. The
    /// app is found on the main actor; its Accessibility tree is read off it.
    @MainActor
    static func readSelection(bundleID: String, write: (String) -> Void = writeLine) async -> CommandStatus {
        let report: any Encodable
        let status: CommandStatus
        if let front = FrontApp.running(bundleID) {
            switch await SelectionReader.read(from: front) {
            case .selected(let selection):
                report = SelectionReport(selection)
                status = .success
            case .nothing(let reason):
                report = ["nothing": reason]
                status = .failure
            }
        } else {
            report = ["error": "\(bundleID) is not running, or has no window to find its process by"]
            status = .failure
        }
        do {
            write(try jsonLine(report))
            return status
        } catch {
            writeError("could not encode the report: \(error)")
            return .internalError
        }
    }

    static func writeLine(_ line: String) {
        print(line)
        fflush(stdout)  // each lookup's line must survive whatever the next one does
    }

    static func writeError(_ line: String) {
        FileHandle.standardError.write(Data("error: \(line)\n".utf8))
    }

    /// One line: no pretty-printing, so a repeat run is valid JSON Lines.
    static func jsonLine(_ value: any Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// One lookup, as `--lookup` reports it. Fields that do not apply to the outcome are left out.
struct LookupReport: Encodable, Equatable {
    let term: String
    let outcome: String
    let startedAtSeconds: Double
    let tookMilliseconds: Double
    var dictionaries: [String]?
    var headwords: [String]?
    var matches: [String]?
    var bytes: [Int]?
    /// One per entry, so a run through the real XPC path shows that every record arrived — not
    /// only the first of each dictionary — and that each carries its identity.
    var entryIDs: [String]?
    /// One per entry: how many senses it has, and how precisely they can be addressed. This is
    /// what makes a sense-level regression visible from outside the process.
    var senseCounts: [Int]?
    var senseKeyKinds: [String]?
    var unreadable: [String]?
    var serviceFailure: String?
    /// The plain-text fallback, whole: a truncated definition under the name "text" would read as
    /// the complete one.
    var text: String?

    init(term: String, outcome: LookupOutcome, startedAt: Duration, took: Duration) {
        self.term = term
        startedAtSeconds = (startedAt.milliseconds / 100).rounded() / 10
        tookMilliseconds = took.milliseconds.rounded()
        switch outcome {
        case .entries(let entries, let unreadable):
            self.outcome = "entries"
            dictionaries = entries.map(\.dictionary.name)
            headwords = entries.map(\.headword)
            matches = entries.map(\.match.rawValue)
            bytes = entries.map(\.html.utf8.count)
            entryIDs = entries.map { $0.entryID ?? "" }
            senseCounts = entries.map(\.senseCount)
            senseKeyKinds = entries.map(\.senseKeyKind.rawValue)
            self.unreadable = unreadable
        case .plainText(let text, let failure):
            self.outcome = "plainText"
            serviceFailure = failure
            self.text = text
        case .notFound(let failure):
            self.outcome = "notFound"
            serviceFailure = failure
        }
    }
}

/// A word under a point, as `--read-point` reports it — with which path read it, and how far to
/// trust it. The path matters: Accessibility is exact, the recogniser can be *wrong*.
struct PointReport: Encodable, Equatable {
    let text: String
    let sentence: String?
    let lemma: String
    let app: String
    let bundleID: String?
    /// `accessibilityTextRange` | `accessibilityTextMarkers` | `accessibilityBoundsScan` |
    /// `opticalRecognition`
    let captureSource: String
    let confidence: Double
    let context: String
    let milliseconds: Double

    init(_ selection: Selection, milliseconds: Double) {
        text = selection.text
        sentence = selection.sentence
        lemma = Lemmatizer.lemma(
            of: selection.text, in: selection.sentence, at: selection.rangeInSentence).text
        app = selection.appName
        bundleID = selection.bundleID
        captureSource = selection.quality.source.rawValue
        confidence = selection.quality.confidence
        context = selection.quality.context.rawValue
        self.milliseconds = milliseconds
    }
}

/// A selection, as `--read-selection` reports it — with its capture quality, so exact Accessibility
/// text is never confused with a degraded capture.
struct SelectionReport: Encodable, Equatable {
    let text: String
    let sentence: String?
    let lemma: String
    let lemmaBasis: String
    let app: String
    let bundleID: String?
    /// A page URL and a file are reported apart, as they are now stored apart: a page URL can
    /// itself be a `file://`, so one field could never separate them.
    let page: String?
    let document: String?
    let title: String?
    /// `page` | `document` | `appOnly` — 12 of 17 apps measured could say nothing beyond their name.
    let precision: String
    let captureSource: String
    let confidence: Double
    let context: String

    init(_ selection: Selection) {
        let lemma = Lemmatizer.lemma(of: selection.text, in: selection.sentence, at: selection.rangeInSentence)
        text = selection.text
        sentence = selection.sentence
        self.lemma = lemma.text
        lemmaBasis = "\(lemma.basis)"
        app = selection.appName
        bundleID = selection.bundleID
        page = selection.place.page
        document = selection.place.document
        title = selection.place.title
        precision = selection.place.precision.rawValue
        captureSource = selection.quality.source.rawValue
        confidence = selection.quality.confidence
        context = selection.quality.context.rawValue
    }
}

private extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
