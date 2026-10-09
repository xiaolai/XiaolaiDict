import Foundation
import os
import XiaolaiDictBase

/// The CLIs a reader may have signed in to.
public enum CLITool: String, Sendable, Equatable, CaseIterable {
    case claude
    case codex

    /// The program's name on disk.
    public var executableName: String { rawValue }
}

/// Where a CLI was found.
public enum CLISource: Sendable, Equatable {
    /// The path the reader gave.
    case override
    /// One of the directories the installers use.
    case searchDirectory
    /// The reader's login shell's `PATH` — and that `PATH`, where the shell said it, which the program may need to run.
    case loginShell(searchPath: String?)
}

/// What looking for a CLI found.
public enum CLILocation: Sendable, Equatable {
    case found(URL, CLISource)
    /// The reader gave a path, and it is not a program. **Nothing else is tried**: they named it because the one this
    /// would find is not the one they mean.
    case overrideUnusable(path: String)
    case notFound
}

/// **The reader's login shell, and how it is asked where a program is** — the shell their account names, because that
/// is the one whose profile sets the `PATH` their Terminal has.
///
/// zsh, bash and the other POSIX shells are asked as login and interactive shells (`-l -i -c`), so both the profile and
/// the rc file run; fish the same, in fish's own syntax. Each prints where the program is, then its `PATH` on a line of
/// its own after `searchPathMarker`. A shell this does not know how to ask — csh takes `-l` only alone — is not guessed
/// at: zsh, macOS's own, is asked instead.
public struct LoginShell: Sendable, Equatable {
    /// How a shell's command line is written.
    enum Dialect: Sendable, Equatable {
        case posix
        case fish
    }

    public let executable: URL
    let dialect: Dialect

    /// What the line carrying the shell's `PATH` starts with.
    static let searchPathMarker = "XIAOLAIDICT_SEARCH_PATH="

    /// The shell when the account names none this can ask.
    static let fallback = URL(fileURLWithPath: "/bin/zsh")

    /// The shell at `accountShell` — the account's `pw_shell` — where it is one this can ask, else zsh.
    init(accountShell: String?) {
        let dialects: [String: Dialect] = ["zsh": .posix, "bash": .posix, "sh": .posix, "ksh": .posix, "dash": .posix,
                                           "fish": .fish]
        guard let accountShell, accountShell.hasPrefix("/"),
              let dialect = dialects[URL(fileURLWithPath: accountShell).lastPathComponent]
        else {
            executable = Self.fallback
            dialect = .posix
            return
        }
        executable = URL(fileURLWithPath: accountShell)
        self.dialect = dialect
    }

    /// The shell the account this app runs as names.
    static var account: LoginShell {
        LoginShell(accountShell: getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) })
    }

    /// The arguments that ask it where `tool` is, and then for its `PATH`.
    func arguments(for tool: CLITool) -> [String] {
        let path = switch dialect {
        case .posix: "\"$PATH\""
        case .fish: "(string join : $PATH)"
        }
        return ["-l", "-i", "-c", "command -v \(tool.executableName); printf '%s%s\\n' '\(Self.searchPathMarker)' \(path)"]
    }
}

/// **Finds the reader's own CLI** (plan §5): the path they gave, else `~/.local/bin`, `/opt/homebrew/bin` and
/// `/usr/local/bin` — where the installers put them — else whatever their login shell finds, because an app opened from
/// the Dock does not have the `PATH` their Terminal has. **And says what `PATH` the program runs with**, for the same
/// reason: a CLI installed by a package manager is often a script its interpreter runs (`#!/usr/bin/env node`).
///
/// **Only a path to a program of that name is ever taken** — never a path a web page or a model offered, and never a
/// line of a shell profile's output that merely looks like one.
public struct CLILocator: Sendable {
    let searchDirectories: [URL]
    let loginShell: LoginShell?
    let shellTimeout: Duration

    private static var log: Logger { Logger(subsystem: XiaolaiDictIdentity.app, category: "providers") }

    public static let standard = CLILocator(
        searchDirectories: [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ],
        loginShell: .account, shellTimeout: .seconds(5))

    init(searchDirectories: [URL], loginShell: LoginShell?, shellTimeout: Duration) {
        self.searchDirectories = searchDirectories
        self.loginShell = loginShell
        self.shellTimeout = shellTimeout
    }

    /// Where `tool` is: at `override` where the reader gave one, else the first of the search, else the login shell's.
    public func locate(_ tool: CLITool, override: String?) async -> CLILocation {
        if let override {
            let program = URL(fileURLWithPath: override)
            return Self.isProgram(program) ? .found(program, .override) : .overrideUnusable(path: override)
        }
        for directory in searchDirectories {
            let program = directory.appending(path: tool.executableName, directoryHint: .notDirectory)
            if Self.isProgram(program) { return .found(program, .searchDirectory) }
        }
        if let (program, searchPath) = await askLoginShell(for: tool) {
            return .found(program, .loginShell(searchPath: searchPath))
        }
        return .notFound
    }

    /// **The `PATH` `program`, found from `source`, runs with**: its own directory first — where an installer puts the
    /// interpreter a script names, `node` beside `claude` under nvm or Homebrew — then the login shell's `PATH` where it
    /// was asked, then the installers' directories, then `inherited`, this app's own. Each directory once, and only
    /// absolute ones: a relative one would be resolved against wherever the child happens to run.
    func searchPath(for program: URL, source: CLISource,
                    inherited: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        var directories = [program.deletingLastPathComponent().path]
        if case .loginShell(let shellPath?) = source { directories += Self.directories(in: shellPath) }
        directories += searchDirectories.map(\.path)
        directories += Self.directories(in: inherited ?? "")
        var seen: Set<String> = []
        return directories.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func directories(in path: String) -> [String] {
        path.split(separator: ":").map(String.init)
    }

    /// The last line the shell printed that is an absolute path to a program named `tool`, and the `PATH` it printed
    /// last, within the bound. Standard input is closed at once, so a profile that asks a question gets no answer; one
    /// that hangs is ended, and so is one whose caller gives up.
    private func askLoginShell(for tool: CLITool) async -> (URL, String?)? {
        guard let loginShell,
              let child = try? ChildProcess.start(ChildLaunch(
                  executable: loginShell.executable, arguments: loginShell.arguments(for: tool),
                  workingDirectory: FileManager.default.homeDirectoryForCurrentUser))
        else { return nil }
        child.closeInput()
        let timeout = shellTimeout
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            child.end(.deadline)
        }
        defer {
            timer.cancel()
            child.end(.retired)
        }
        let (found, searchPath) = await withTaskCancellationHandler {
            await Self.read(child, for: tool)
        } onCancel: {
            child.end(.cancelled)
        }
        guard let found else {
            Self.log.info("the login shell found no \(tool.executableName, privacy: .public)")
            return nil
        }
        return (found, searchPath)
    }

    /// The program and the `PATH` the shell printed, each the last one it printed, up to `shellLineLimit` lines.
    private static func read(_ shell: ChildProcess, for tool: CLITool) async -> (URL?, String?) {
        var found: URL?
        var searchPath: String?
        var lines = 0
        while lines < shellLineLimit, let line = try? await shell.nextLine() {
            lines += 1
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(LoginShell.searchPathMarker) {
                searchPath = String(text.dropFirst(LoginShell.searchPathMarker.count))
                continue
            }
            guard text.hasPrefix("/") else { continue }
            let program = URL(fileURLWithPath: text)
            if program.lastPathComponent == tool.executableName, isProgram(program) { found = program }
        }
        return (found, searchPath)
    }

    /// A profile that prints without end is not read without end.
    private static let shellLineLimit = 256

    /// A regular file — following links — that this user may run. A directory with the program's name is not one.
    static func isProgram(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}
