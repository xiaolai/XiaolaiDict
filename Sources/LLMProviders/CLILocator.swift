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
    /// The reader's login shell's `PATH`.
    case loginShell
}

/// What looking for a CLI found.
public enum CLILocation: Sendable, Equatable {
    case found(URL, CLISource)
    /// The reader gave a path, and it is not a program. **Nothing else is tried**: they named it because the one this
    /// would find is not the one they mean.
    case overrideUnusable(path: String)
    case notFound
}

/// **Finds the reader's own CLI** (plan §5): the path they gave, else `~/.local/bin`, `/opt/homebrew/bin` and
/// `/usr/local/bin` — where the installers put them — else whatever their login shell finds, because an app opened from
/// the Dock does not have the `PATH` their Terminal has.
///
/// **Only a path to a program of that name is ever taken** — never a path a web page or a model offered, and never a
/// line of a shell profile's output that merely looks like one.
public struct CLILocator: Sendable {
    let searchDirectories: [URL]
    let loginShell: URL?
    let shellTimeout: Duration

    private static var log: Logger { Logger(subsystem: XiaolaiDictIdentity.app, category: "providers") }

    public static let standard = CLILocator(
        searchDirectories: [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ],
        loginShell: URL(fileURLWithPath: "/bin/zsh"), shellTimeout: .seconds(5))

    init(searchDirectories: [URL], loginShell: URL?, shellTimeout: Duration) {
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
        if let program = await askLoginShell(for: tool) { return .found(program, .loginShell) }
        return .notFound
    }

    /// `zsh -lic 'command -v <name>'` — login and interactive, so the reader's profile and `.zshrc` set the `PATH`.
    static func loginShellArguments(for tool: CLITool) -> [String] {
        ["-lic", "command -v \(tool.executableName)"]
    }

    /// The last line the shell printed that is an absolute path to a program named `tool`, within the bound. Standard
    /// input is closed at once, so a profile that asks a question gets no answer, and one that hangs is ended.
    private func askLoginShell(for tool: CLITool) async -> URL? {
        guard let loginShell,
              let child = try? ChildProcess.start(ChildLaunch(
                  executable: loginShell, arguments: Self.loginShellArguments(for: tool),
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
        var found: URL?
        var lines = 0
        while lines < Self.shellLineLimit, let line = try? await child.nextLine() {
            lines += 1
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("/") else { continue }
            let program = URL(fileURLWithPath: text)
            if program.lastPathComponent == tool.executableName, Self.isProgram(program) { found = program }
        }
        if found == nil { Self.log.info("the login shell found no \(tool.executableName, privacy: .public)") }
        return found
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
