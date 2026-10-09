import Foundation
import os
import XiaolaiDictBase

/// **What the reader must do before a CLI can answer** — a kind, never a sentence: the words are the view layer's
/// (ADR-0025). Every case but `ready` names something the reader can act on.
public enum CLIReadiness: Sendable, Equatable {
    /// Nothing found where the CLI is installed, nor on the reader's login shell's `PATH`: install it.
    case notInstalled
    /// The path the reader gave is not a program: correct it, or clear it to have the CLI found.
    case overrideUnusable(path: String)
    /// The CLI answers that nobody is signed in: sign in to it in Terminal (`claude`, `codex login`). Never done for
    /// the reader — the sign-in is theirs.
    case notSignedIn
    /// The CLI refuses an argument or a method this app needs: update it.
    case tooOld(version: String?)
    /// The CLI started but did not answer — rate limited, unreachable, timed out, refused: try again later.
    case unavailable(ProviderFailure)
    /// It answered one trivial question, in `answeredIn` — the whole answer, from the question being written.
    case ready(version: String?, answeredIn: Duration)

    /// What the locator's answer means for the reader where it found nothing to start; nil where it found the CLI,
    /// and the preflight decides.
    public init?(_ location: CLILocation) {
        switch location {
        case .notFound: self = .notInstalled
        case .overrideUnusable(let path): self = .overrideUnusable(path: path)
        case .found: return nil
        }
    }
}

/// **The preflight both CLIs share** (plan §5): the version the CLI prints, then one trivial question through the
/// provider's own session — so the process it starts stays warm for the reader's first real one. It never prompts and
/// never starts a sign-in.
enum CLIPreflight {
    /// Nothing of the reader's in it, and an answer of a word or two.
    static let question = GenerationRequest(instructions: "", prompt: "Reply with the single word: ready",
                                            maxTokens: 8, temperature: 0)

    static func readiness<Wire: ResidentWire>(of executable: URL, asking session: ResidentSession<Wire>) async
        -> CLIReadiness {
        let version = await CLIVersion.read(executable, in: session.launch.workingDirectory,
                                             searchPath: session.launch.searchPath)
        let start = ContinuousClock.now
        do {
            _ = try await session.ask(question)
            return .ready(version: version, answeredIn: ContinuousClock.now - start)
        } catch {
            switch error {
            case .unauthorised:
                return .notSignedIn
            case .badShape(CodexCLIWire.methodNotFound):
                return .tooOld(version: version)
            default:
                if let exit = await session.lastExit(), CLIDiagnosis.saysTooOld(exit.diagnostics) {
                    return .tooOld(version: version)
                }
                return .unavailable(error)
            }
        }
    }
}

/// **A CLI's version, as its `--version` prints it**: `2.1.294 (Claude Code)`, `codex-cli 0.161.0`.
enum CLIVersion {
    /// The version `executable` prints, run in `directory` with `searchPath` — the `PATH` the CLI itself runs with, since
    /// a script's interpreter is found on it — or nil where it prints none within `timeout`, or the caller gives up.
    static func read(_ executable: URL, in directory: URL, searchPath: String?,
                     timeout: Duration = .seconds(5)) async -> String? {
        guard let child = try? ChildProcess.start(ChildLaunch(executable: executable, arguments: ["--version"],
                                                              workingDirectory: directory, searchPath: searchPath))
        else { return nil }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            child.end(.deadline)
        }
        defer {
            timer.cancel()
            child.end(.retired)
        }
        let printed = await withTaskCancellationHandler {
            var printed: [String] = []
            while printed.count < Self.lineLimit, let line = try? await child.nextLine() {
                printed.append(String(decoding: line, as: UTF8.self))
            }
            return printed
        } onCancel: {
            child.end(.cancelled)
        }
        return parse(printed.joined(separator: "\n"))
    }

    /// The first word that starts with a digit and holds a dot.
    static func parse(_ text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace })
            .first { word in word.first.map { ("0"..."9").contains($0) } == true && word.contains(".") }
            .map(String.init)
    }

    private static let lineLimit = 16
}

/// **What a CLI's error output says that a reader can act on** — read for a fixed marker, never shown or logged.
///
/// The markers are what each CLI's argument parser prints for an argument it does not know (measured 2026-10-09):
/// `claude` (commander) `error: unknown option '--x'`; `codex` (clap) `error: unexpected argument '--x' found`.
enum CLIDiagnosis {
    static func saysTooOld(_ diagnostics: String) -> Bool {
        markers.contains { diagnostics.contains($0) }
    }

    private static let markers = ["unknown option", "unexpected argument"]
}
