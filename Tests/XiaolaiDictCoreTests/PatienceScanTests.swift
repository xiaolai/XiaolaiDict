import Foundation
import Testing
import XiaolaiDictTestSupport

/// **No test waits on a bound that measures the Mac's load** — mechanically, so a fifth instance cannot arrive
/// looking green.
///
/// The class, found four times (c6b6260, 839fe6f, 4bc5bdc, and the commits with this scan): a wait or deadline in a
/// test whose only job is to stop a defect hanging the run, set to a few seconds — a poll of 500 looks of 10 ms, a
/// `.timeLimit` of one minute, a product deadline left at its shipped three seconds while the test expects the answer,
/// a sleep of ten seconds standing for "never". A full parallel run on a busy Mac starves the main actor and the
/// cooperative pool for a minute at a time, and each of those bounds then ran out on a condition that would have
/// held a moment later. `Patience` is the one bound; this holds every test file to it, in five shapes:
///
/// | Rule | What it refuses | Why |
/// |---|---|---|
/// | `handRolledPolls` | a loop whose body sleeps or yields, outside `Patience` | a count of looks is a clock in disguise |
/// | `timeLimits` | a `.timeLimit` that is not `Patience.limitMinutes` | the limit is a hang guard too |
/// | `neverStandIns` | a sleep or `withDeadline` of ten seconds or more that is not `Patience.never` | "never" that ends is a stopwatch |
/// | `literalBounds` | a number on a waiting or deadline label, where a `Patience` name belongs | a short bound measures load; a long one competes with the limit |
/// | `unnamedDeadlines` | a client built with its shipped deadline left implicit | the default is short, and invisible |
///
/// **A short bound that is the test's subject is declared, never silent.** A deadline the test is *about* — against a
/// fake that never answers — and a window that only gives an absence a chance to be broken (it can miss a defect on a
/// slow Mac, never invent one) are legitimate and short on purpose. Each is in `declared` with its reason and the
/// number of times its file spells it, so one more of the same spelling in the same file is new and must say why.
///
/// The rules read text, not a syntax tree: a full-line comment is blanked, a loop's body is found by its braces, an
/// argument by its label after `(` or `,`. That is wide enough for how these tests are written, and each rule has a
/// positive control below so a rule that stopped matching would say so.
struct PatienceScanTests {
    // MARK: - The walk

    /// One finding: where it is, and the text a declaration names it by.
    struct Line: Sendable, Equatable {
        let file: String
        let number: Int
        let text: String
    }

    /// One file's code as UTF-8, full-line comments blanked line for line so numbers stay true.
    struct File: Sendable {
        let name: String
        let lines: [String]
        let bytes: [UInt8]
        /// The byte offset each line starts at.
        let starts: [Int]

        init(name: String, text: String) {
            self.name = name
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String(line)
            }
            bytes = Array(lines.joined(separator: "\n").utf8)
            starts = lines.reduce(into: [0]) { $0.append($0.last! + $1.utf8.count + 1) }
        }

        /// The 1-based line holding a byte offset.
        func line(of offset: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return low + 1
        }

        /// Every byte offset at which `needle` starts.
        func occurrences(of needle: String) -> [Int] {
            let wanted = Array(needle.utf8)
            guard let first = wanted.first, bytes.count >= wanted.count else { return [] }
            var found: [Int] = []
            var start = 0
            while start <= bytes.count - wanted.count {
                if bytes[start] == first, bytes[start..<(start + wanted.count)].elementsEqual(wanted) { found.append(start) }
                start += 1
            }
            return found
        }

        /// The text from `start`, an opening `open`, to its matching `close`.
        func balanced(from start: Int, open: UInt8, close: UInt8) -> String? {
            var depth = 0
            for index in start..<bytes.count {
                if bytes[index] == open { depth += 1 }
                if bytes[index] == close {
                    depth -= 1
                    if depth == 0 { return String(decoding: bytes[start...index], as: UTF8.self) }
                }
            }
            return nil
        }

        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

        /// A loop's opening brace: the first `{` outside parentheses — `withLock({ $0 })` in a condition is not it.
        func bodyBrace(after offset: Int) -> Int? {
            var depth = 0
            for index in offset..<bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "("): depth += 1
                case UInt8(ascii: ")"): depth -= 1
                case UInt8(ascii: "{") where depth == 0: return index
                default: break
                }
            }
            return nil
        }

        /// The last byte before `offset` that is not whitespace.
        func lastNonBlank(before offset: Int) -> UInt8? {
            bytes[..<offset].last { $0 != 0x20 && $0 != 0x0A && $0 != 0x09 }
        }
    }

    static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Files this scan never reads: the one wait itself, and this scan, whose fixtures spell every offence.
    static let exempt: Set<String> = ["Patience.swift", "PatienceScanTests.swift"]

    /// A file from each target that waits, which the walk must read — a walk that shrank would pass on what remains.
    static let canaries = ["WiringFixture.swift", "FakeCLI.swift", "ModelServiceTests.swift", "PatienceTests.swift",
                           "LookupKeepRaceTests.swift", "HoverWatcherTests.swift", "SelectionReaderTests.swift"]

    /// The walk, made once for every rule here.
    static let walked = Result { try walk() }
    static func files() throws -> [File] { try walked.get() }

    static func walk() throws -> [File] {
        var failure: (any Error)?
        guard let walk = FileManager.default.enumerator(
            at: tests, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in failure = error; return false })
        else { throw SourceScan.Failure.unreadable(path: tests.path, underlying: nil) }
        var found: [File] = []
        for case let url as URL in walk where url.pathExtension == "swift" && !exempt.contains(url.lastPathComponent) {
            found.append(File(name: url.lastPathComponent, text: try String(contentsOf: url, encoding: .utf8)))
        }
        if let failure { throw SourceScan.Failure.unreadable(path: tests.path, underlying: failure) }
        return found
    }

    // MARK: - The rules

    /// What a loop's body does that makes it a poll.
    static let pauses = ["Task.sleep(", "Thread.sleep(", "Task.yield()", "usleep(", "RunLoop.main.run("]

    /// **A loop whose body sleeps or yields** — a poll of its own. Its bound, a count of looks or a clock, is the
    /// defect; `Patience.until` is the copy that has none. `for await` over a stream does not poll.
    static func handRolledPolls(_ file: File) -> [Line] {
        var found: [Line] = []
        for (index, text) in file.lines.enumerated() {
            let trimmed = text.drop { $0 == " " || $0 == "\t" }
            guard trimmed.hasPrefix("for ") && trimmed.contains(" in ") && !trimmed.hasPrefix("for await")
                    || trimmed.hasPrefix("while ") || trimmed.hasPrefix("repeat ") || trimmed.hasPrefix("repeat{"),
                  let brace = file.bodyBrace(after: file.starts[index]),
                  let body = file.balanced(from: brace, open: UInt8(ascii: "{"), close: UInt8(ascii: "}")),
                  pauses.contains(where: body.contains)
            else { continue }
            found.append(Line(file: file.name, number: index + 1, text: text))
        }
        return found
    }

    /// **A time limit other than the shared one.** Swift Testing's limit is a hang guard like any other wait.
    static func timeLimits(_ file: File) -> [Line] {
        file.lines.enumerated().compactMap { index, text in
            text.contains(".timeLimit(") && !text.contains(".timeLimit(.minutes(Patience.limitMinutes))")
                ? Line(file: file.name, number: index + 1, text: text) : nil
        }
    }

    /// The seconds a literal duration spells — `.seconds(n)`, `.milliseconds(n)`, `.minutes(n)`, `.zero`, the same
    /// with `Duration` in front, or a bare number of seconds where `bareSeconds` — and nil for anything that is not a
    /// literal, which a rule leaves alone: a named bound says what it is.
    static func seconds(of expression: String, bareSeconds: Bool) -> Double? {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Duration", with: "").replacingOccurrences(of: "_", with: "")
        if text == ".zero" { return 0 }
        for (unit, scale) in [(".seconds(", 1.0), (".milliseconds(", 0.001), (".minutes(", 60.0)]
        where text.hasPrefix(unit) && text.hasSuffix(")") {
            return Double(text.dropFirst(unit.count).dropLast()).map { $0 * scale }
        }
        return bareSeconds ? Double(text) : nil
    }

    /// The labels a wait or a deadline is given under, across the tests and the product types they build.
    static let boundLabels = [
        "within", "bound", "budget", "deadline", "timeout", "limit", "shellTimeout", "turnTimeout", "openTimeout",
        "versionTimeout", "captureDeadline", "prewarmWait", "shutdownLimit",
    ]

    /// Each `label:` argument in a file with the expression it is given, up to the next comma or close at its own
    /// depth. A parameter's default — `label: Duration = .seconds(3)` — counts as given: every caller that omits it
    /// gets it.
    static func arguments(labelled labels: [String], in file: File) -> [(line: Int, label: String, value: String)] {
        var found: [(Int, String, String)] = []
        for label in labels {
            for start in file.occurrences(of: "\(label):") {
                // The whole label — `timeout:` inside `shellTimeout:` is not it — and an argument's, after `(` or `,`.
                if start > 0, let previous = Unicode.Scalar(file.bytes[start - 1]) as Unicode.Scalar?,
                   previous.properties.isAlphabetic || ("0"..."9").contains(previous) { continue }
                guard let before = file.lastNonBlank(before: start), before == UInt8(ascii: "(") || before == UInt8(ascii: ",")
                else { continue }
                var index = start + label.utf8.count + 1
                var depth = 0
                while index < file.bytes.count {
                    let byte = file.bytes[index]
                    if byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") { depth += 1 }
                    if byte == UInt8(ascii: ")") || byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}") {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    if byte == UInt8(ascii: ","), depth == 0 { break }
                    index += 1
                }
                var given = file.text((start + label.utf8.count + 1)..<index).trimmingCharacters(in: .whitespacesAndNewlines)
                if let equals = given.range(of: " = "), !given[..<equals.lowerBound].contains("(") {
                    given = String(given[equals.upperBound...])
                }
                found.append((file.line(of: start), label, given))
            }
        }
        return found
    }

    /// **A number on a waiting or deadline label**, or in a semaphore's `.now() + n`. Under `Patience.wait` it
    /// measures the Mac's load; at or over it, it is a hang guard or a never spelled by hand, which competes with the
    /// limit — ten minutes stood for never under a limit of two, and is the limit itself now. A bound in a test is a
    /// `Patience` name, a name of the test's own, or a short subject declared below.
    static func literalBounds(_ file: File) -> [Line] {
        var found = arguments(labelled: boundLabels, in: file).compactMap { line, label, value -> Line? in
            seconds(of: value, bareSeconds: label == "timeout") == nil
                ? nil : Line(file: file.name, number: line, text: "\(label): \(value)")
        }
        for start in file.occurrences(of: ".now() + ") {
            let digits = file.bytes[(start + 9)...].prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: ".") }
            if !digits.isEmpty {
                found.append(Line(file: file.name, number: file.line(of: start), text: ".now() + \(String(decoding: digits, as: UTF8.self))"))
            }
        }
        return found
    }

    /// **A sleep or deadline of ten seconds or more, spelled as a number** — it stands for "never", and a never
    /// that ends is a stopwatch: 839fe6f's ten seconds was outlasted by a starved suite.
    static func neverStandIns(_ file: File) -> [Line] {
        var found: [Line] = []
        for opening in ["Task.sleep(for:", "withDeadline("] {
            for start in file.occurrences(of: opening) {
                let open = start + opening.utf8.count - (opening.hasSuffix("(") ? 1 : 0)
                let call = opening.hasSuffix("(")
                    ? file.balanced(from: open, open: UInt8(ascii: "("), close: UInt8(ascii: ")")).map { String($0.dropFirst().dropLast()) }
                    : file.balanced(from: start + "Task.sleep".utf8.count, open: UInt8(ascii: "("), close: UInt8(ascii: ")"))
                        .map { String($0.dropFirst("(for:".count).dropLast()) }
                guard let argument = call, let seconds = seconds(of: argument, bareSeconds: false), seconds >= 10 else { continue }
                found.append(Line(file: file.name, number: file.line(of: start),
                                  text: "\(opening)\(opening.hasSuffix(":") ? " " : "")\(argument.trimmingCharacters(in: .whitespaces))"))
            }
        }
        return found
    }

    /// The product types whose shipped deadline is shorter than `Patience.wait`, and the label each takes it under. A
    /// test that leaves it implicit waits on the shipped value without saying so — the defect in
    /// `LookupRunnerSpellingTests`, whose service missed `DictionaryClient`'s three seconds under load and whose test
    /// then waited out its whole time limit for a question nothing would ask.
    static let deadlineLabels: [(call: String, label: String)] = [
        ("DictionaryClient(", "deadline"), ("ModelClient(", "deadline"), ("OpenAICompatibleProvider(", "timeout"),
        ("ModelService(", "prewarmWait"), ("HoverReader(", "captureDeadline"), ("CLIVersion.read(", "timeout"),
        ("CLILocator(", "shellTimeout"), ("ReviewRoute(", "limit"), ("ResidentConfiguration(", "turnTimeout"),
        // `StudyDictionary.settled(bound:)` ships two seconds; `FormAuthority` and `LookupRecorder` take no default.
        (".settled()", "bound"),
    ]

    /// **A client built with its deadline left implicit.** A declaration (`func`) or a mention in a string is not a
    /// call.
    static func unnamedDeadlines(_ file: File) -> [Line] {
        var found: [Line] = []
        for (call, label) in deadlineLabels {
            for start in file.occurrences(of: call) {
                // The whole name: `ScriptedHoverReader(` is not `HoverReader(`. A call spelled from `.` follows a name.
                if !call.hasPrefix("."), start > 0, let previous = Unicode.Scalar(file.bytes[start - 1]) as Unicode.Scalar?,
                   previous.properties.isAlphabetic || ("0"..."9").contains(previous) { continue }
                let lead = file.text(max(0, start - 6)..<start)
                guard !lead.contains("func "), !lead.contains("\""), !lead.hasSuffix("."),
                      let arguments = file.balanced(from: start + call.utf8.count - (call.hasSuffix("()") ? 2 : 1),
                                                    open: UInt8(ascii: "("),
                                                    close: UInt8(ascii: ")")),
                      !arguments.contains("\(label):") else { continue }
                found.append(Line(file: file.name, number: file.line(of: start), text: "\(call)… without \(label):"))
            }
        }
        return found
    }

    // MARK: - What is declared

    /// A numbered bound or a loop that sleeps, kept on purpose: the file, the text the rule reports, how many times the
    /// file holds it, and why. Exact counts, so a new one of the same spelling is new.
    struct Declared: Sendable {
        let file: String
        let text: String
        let count: Int
        let reason: String
    }

    /// The deadline is the test's subject, against a fake that never answers, or that is held past it.
    static let subject = "the deadline is the subject: what it ends never answers, so its length only sets how long the test takes"
    /// A window that only lets an absence show before the test asserts it.
    static let absence = "a window for an absence: a slow Mac can make it miss a defect, never invent one"
    /// A wait whose subject is that it runs out.
    static let control = "a positive control: a wait that must run out, given no time to"
    /// A budget read against the test's own clock.
    static let fakeClock = "measured against the test's fake clock, `requests.now()`: no wall time passes"
    /// The Accessibility messaging timeout, handed to a fake setter.
    static let messaging = "the Accessibility messaging timeout handed to a fake setter: nothing waits on it"

    static let declared: [Declared] = [
        // Polls kept on purpose.
        Declared(file: "EraseWiringTests.swift", text: "for _ in 0..<3 {", count: 1, reason: absence),
        Declared(file: "EraseWiringTests.swift", text: "for _ in 0..<20 { await Task.yield() }", count: 1, reason: absence),
        Declared(file: "HoverTestFakes.swift", text: "for turn in 0..<250 {", count: 1, reason: absence),
        Declared(file: "ReviewWiringTests.swift", text: "for pressed in [ReviewAction.skip, .postpone] {", count: 1, reason: absence),
        Declared(file: "ModelServiceTests.swift",
                 text: "for _ in 0..<100 where model.requests.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }",
                 count: 1, reason: absence),
        Declared(file: "CardDisclosureTests.swift", text: "for _ in 0..<3 {", count: 1,
                 reason: "turns the run loop three times on this thread to bring a hosted view up to date — no other work is waited for"),
        Declared(file: "CardAnchorTests.swift", text: "for _ in 0..<3 {", count: 1,
                 reason: "turns the run loop three times on this thread to bring a hosted view up to date — no other work is waited for"),
        Declared(file: "CardAnchorTests.swift", text: "for compact in [true, false, true] {", count: 1,
                 reason: "holds the three run-loop turns above, once per card"),
        Declared(file: "AccessibilityBudgetTests.swift", text: "for index in 0..<5 {", count: 1,
                 reason: "a read nothing can interrupt, simulated by blocking its thread — the work under test, not a wait"),
        Declared(file: "AccessibilityBudgetTests.swift", text: "for timeout: Float in [0.25, 1.0, 0.25, 1.0] {", count: 1,
                 reason: "a read nothing can interrupt, simulated by blocking its thread — the work under test, not a wait"),
        Declared(file: "AccessibilityBudgetTests.swift",
                 text: "while !release.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }", count: 1,
                 reason: "a blocking read held until the test lets it go, right after the test's own bounded wait"),
        Declared(file: "ResidentSessionTests.swift", text: "for _ in 0..<4 {", count: 1,
                 reason: "the subject is the idle clock: real gaps that together outlast it, each with four seconds of room"),
        // Bounds kept short on purpose.
        Declared(file: "StudyDictionaryAutomaticTests.swift", text: "bound: .milliseconds(50)", count: 1, reason: subject),
        Declared(file: "PatienceTests.swift", text: "within: .zero", count: 2, reason: control),
        Declared(file: "ReviewWiringTests.swift", text: "within: .zero", count: 1, reason: control),
        Declared(file: "ResidentSessionTests.swift", text: "within: .zero", count: 1,
                 reason: "asks whether there is an outcome yet, and waits for none"),
        Declared(file: "PollTests.swift", text: "within: .milliseconds(30)", count: 1, reason: control),
        Declared(file: "TemporaryDefaultsTests.swift", text: "within: .seconds(1)", count: 2, reason: absence),
        Declared(file: "PinnedNoteControllerTests.swift", text: "within: .milliseconds(300)", count: 1, reason: absence),
        Declared(file: "LocalModelCoordinatorTests.swift", text: "within: .milliseconds(500)", count: 1, reason: absence),
        Declared(file: "WatchdogTests.swift", text: "limit: .milliseconds(100)", count: 2,
                 reason: subject + "; the run that must keep to it is read only where it did"),
        Declared(file: "SenseReportTests.swift", text: "limit: .milliseconds(100)", count: 2,
                 reason: subject + "; a run whose fast rung load pushed past it is run again"),
        Declared(file: "ModelHostProbeTests.swift", text: "within: .milliseconds(300)", count: 1, reason: subject),
        Declared(file: "SpellingReportTests.swift", text: "within: .milliseconds(50)", count: 1, reason: subject),
        Declared(file: "CardAnchorTests.swift", text: "budget: .milliseconds(200)", count: 2, reason: subject),
        Declared(file: "IdleExitTests.swift", text: "within: .milliseconds(100)", count: 1, reason: subject),
        Declared(file: "DictionaryClientTests.swift", text: "deadline: .milliseconds(100)", count: 1, reason: subject),
        Declared(file: "HoverAuditTests.swift", text: "deadline: .milliseconds(50)", count: 1, reason: subject),
        Declared(file: "WindowActionsWiringTests.swift", text: "deadline: .milliseconds(50)", count: 2, reason: subject),
        Declared(file: "LookupRunnerTests.swift", text: "deadline: .milliseconds(50)", count: 11, reason: subject),
        Declared(file: "LookupRunnerTests.swift", text: "deadline: .milliseconds(30)", count: 1, reason: subject),
        Declared(file: "LookupRunnerTests.swift", text: "deadline: .milliseconds(10)", count: 1, reason: subject),
        Declared(file: "ProviderClientTests.swift", text: "deadline: .milliseconds(50)", count: 1, reason: subject),
        Declared(file: "ReminderWiringTests.swift", text: "limit: .milliseconds(200)", count: 1, reason: subject),
        Declared(file: "HoverWatcherSequenceTests.swift", text: "captureDeadline: .milliseconds(20)", count: 1, reason: subject),
        Declared(file: "ModelClientTests.swift", text: "shutdownLimit: .milliseconds(50)", count: 2, reason: subject),
        Declared(file: "LocalModelCoordinatorTests.swift", text: "shutdownLimit: .milliseconds(50)", count: 1, reason: subject),
        Declared(file: "ModelServiceTests.swift", text: "prewarmWait: .milliseconds(50)", count: 2, reason: subject),
        Declared(file: "CLILocatorTests.swift", text: "timeout: .milliseconds(500)", count: 1, reason: subject),
        Declared(file: "LoopbackWireTests.swift", text: "timeout: .milliseconds(500)", count: 1, reason: subject),
        Declared(file: "CodexCLIProviderTests.swift", text: "turnTimeout: .seconds(2)", count: 1,
                 reason: subject + "; the silent question is the first, so nothing else must keep to it"),
        Declared(file: "ResidentSessionTests.swift", text: "turnTimeout: .seconds(2)", count: 1,
                 reason: subject + "; the silent question is the first, so nothing else must keep to it"),
        Declared(file: "ResidentSessionTests.swift", text: "turnTimeout: .milliseconds(200)", count: 1, reason: subject),
        Declared(file: "AccessibilityBudgetTests.swift", text: "budget: .milliseconds(500)", count: 1, reason: fakeClock),
        Declared(file: "AccessibilityBudgetTests.swift", text: "budget: .seconds(60)", count: 5, reason: fakeClock),
        Declared(file: "AccessibilityBudgetTests.swift", text: "timeout: 1", count: 6, reason: messaging),
        Declared(file: "SelectionReaderTests.swift", text: "timeout: 1", count: 2, reason: messaging),
        // A shipped default read as itself.
        Declared(file: "ClaudeCLIProviderTests.swift", text: "ResidentConfiguration(… without turnTimeout:", count: 1,
                 reason: "reads the shipped default, which is its subject"),
    ]

    /// The findings a rule makes that `declared` does not account for, exactly.
    static func undeclared(_ rule: (File) -> [Line], in files: [File]) -> [String] {
        let all = files.flatMap(rule)
        func key(_ file: String, _ text: String) -> String { "\(file)|\(text.trimmingCharacters(in: .whitespaces))" }
        let counts = Dictionary(all.map { (key($0.file, $0.text), 1) }, uniquingKeysWith: +)
        let allowed = Dictionary(declared.map { (key($0.file, $0.text), $0.count) }, uniquingKeysWith: +)
        return all.filter { allowed[key($0.file, $0.text)] != counts[key($0.file, $0.text)] }
            .map { "\($0.file):\($0.number): \($0.text.trimmingCharacters(in: .whitespaces))" }
    }

    // MARK: - The tests

    @Test func theWalkReadsEveryTarget() throws {
        let read = try Self.files().map(\.name)
        #expect(SourceScan.unread(Self.canaries, in: read).isEmpty, "the walk missed \(SourceScan.unread(Self.canaries, in: read))")
    }

    @Test func noTestPollsByHand() throws {
        let found = Self.undeclared(Self.handRolledPolls, in: try Self.files())
        #expect(found.isEmpty, "a loop that sleeps is a wait with a clock of its own — use Patience.until:\n\(found.joined(separator: "\n"))")
    }

    @Test func everyTimeLimitIsTheSharedOne() throws {
        let found = Self.undeclared(Self.timeLimits, in: try Self.files())
        #expect(found.isEmpty, "use .timeLimit(.minutes(Patience.limitMinutes)):\n\(found.joined(separator: "\n"))")
    }

    @Test func everyBoundIsPatienceUnlessDeclared() throws {
        let found = Self.undeclared(Self.literalBounds, in: try Self.files())
        #expect(found.isEmpty, "a bound spelled as a number — Patience.wait or Patience.never, or declare the subject:\n\(found.joined(separator: "\n"))")
    }

    @Test func neverIsPatienceNever() throws {
        let found = Self.undeclared(Self.neverStandIns, in: try Self.files())
        #expect(found.isEmpty, "work standing for never sleeps Patience.never:\n\(found.joined(separator: "\n"))")
    }

    @Test func everyClientNamesItsDeadline() throws {
        let found = Self.undeclared(Self.unnamedDeadlines, in: try Self.files())
        #expect(found.isEmpty, "name the deadline — Patience.wait where the answer is expected:\n\(found.joined(separator: "\n"))")
    }

    /// **Every declaration still names something.** One left behind after its finding was fixed would excuse the
    /// next instance of the same spelling.
    @Test func everyDeclarationIsStillFound() throws {
        let files = try Self.files()
        let all = files.flatMap(Self.handRolledPolls) + files.flatMap(Self.timeLimits) + files.flatMap(Self.literalBounds)
            + files.flatMap(Self.neverStandIns) + files.flatMap(Self.unnamedDeadlines)
        let stale = Self.declared.filter { entry in
            !all.contains { $0.file == entry.file && $0.text.trimmingCharacters(in: .whitespaces) == entry.text }
        }
        #expect(stale.isEmpty, "declared and no longer found: \(stale.map { "\($0.file): \($0.text)" })")
        #expect(Self.declared.allSatisfy { !$0.reason.isEmpty })
    }

    // MARK: - Positive controls: each rule fires on what it is for, and not on its fix

    static func fixture(_ text: String) -> File { File(name: "Fixture.swift", text: text) }

    @Test func aCountedPollIsFoundAndPatienceIsNot() {
        let poll = Self.fixture("""
            func f() async {
                for _ in 0..<500 where !done { try? await Task.sleep(for: .milliseconds(10)) }
                while !open {
                    await Task.yield()
                }
                // for _ in 0..<5 { Task.sleep(…) } in prose is not code
                for item in items { use(item) }
                while !state.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
                for await _ in stream { break }
                #expect(await Patience.until { done })
            }
            """)
        #expect(Self.handRolledPolls(poll).map(\.number) == [2, 3, 8])
    }

    @Test func aTimeLimitOtherThanTheSharedOneIsFound() {
        let limits = Self.fixture("""
            @Test(.timeLimit(.minutes(1))) func a() {}
            @Test(.timeLimit(.minutes(Patience.limitMinutes))) func b() {}
            """)
        #expect(Self.timeLimits(limits).map(\.number) == [1])
    }

    @Test func aBoundSpelledAsANumberIsFoundAndANamedOneIsNot() {
        let bounds = Self.fixture("""
            let a = Poll.until(within: .seconds(2)) { true }
            let b = client(deadline: Duration.milliseconds(50), connect: never)
            func helper(timeout: Duration = .seconds(10)) {}
            lane.run(timeout: 1, work)
            _ = semaphore.wait(timeout: .now() + 60)
            let c = Poll.until(within: Patience.wait) { true }
            let d = PanelPlacement.frame(for: size, within: screen)
            let e = configuration(shellTimeout: .seconds(600))
            let f = forEachEntry(limit: 1200)
            """)
        #expect(Self.literalBounds(bounds).map(\.number).sorted() == [1, 2, 3, 4, 5, 8])
    }

    @Test func aNumberStandingForNeverIsFound() {
        let never = Self.fixture("""
            try await Task.sleep(for: .seconds(30))
            try await withDeadline(.seconds(600)) { 1 }
            try await Task.sleep(for: .milliseconds(50))
            try await Task.sleep(for: Patience.never)
            """)
        #expect(Self.neverStandIns(never).map(\.number).sorted() == [1, 2])
    }

    @Test func aClientWithItsDeadlineLeftImplicitIsFound() {
        let clients = Self.fixture("""
            let a = DictionaryClient(connect: { _ in service }, fallback: { _ in nil })
            let b = DictionaryClient(deadline: Patience.wait, connect: { _ in service }, fallback: { _ in nil })
            init(client: DictionaryClient(connect: x)) {}
            let reader = ScriptedDictionaryClient(connect: x)
            await dictionary.settled()
            await dictionary.settled(bound: Patience.wait)
            """)
        #expect(Self.unnamedDeadlines(clients).map(\.number).sorted() == [1, 3, 5])
    }
}
