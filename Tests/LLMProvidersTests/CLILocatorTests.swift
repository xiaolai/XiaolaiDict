import Foundation
@testable import LLMProviders
import Testing
import XiaolaiDictTestSupport

/// **Finding the reader's CLI** (plan §5): their own path first, then the three directories the installers use, then
/// a login shell — because an app opened from the Dock does not have the reader's `PATH`. Each against directories of
/// the test's own and a fake shell; nothing here looks at the real `~/.local/bin` or starts the reader's shell.
struct CLILocatorTests {
    /// An executable named `name` in `directory`, which is made.
    static func install(_ name: String, in directory: URL, executable: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        return file
    }

    static func locator(_ directories: [URL], shell: URL? = nil,
                        timeout: Duration = .seconds(5)) -> CLILocator {
        CLILocator(searchDirectories: directories, loginShell: shell, shellTimeout: timeout)
    }

    /// The order the plan names, and the shell `zsh -lic`, never anything a web page or a model said.
    @Test func theStandardSearchIsTheReadersOwnBinDirectoriesThenALoginShell() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(CLILocator.standard.searchDirectories.map(\.path) == [
            home.appending(path: ".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
        ])
        #expect(CLILocator.standard.loginShell?.path == "/bin/zsh")
        #expect(CLILocator.loginShellArguments(for: .codex) == ["-lic", "command -v codex"])
    }

    @Test func theReadersOwnPathComesFirst() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        let own = try Self.install("claude", in: scratch.appending("own"))
        let listed = scratch.appending("bin")
        _ = try Self.install("claude", in: listed)
        #expect(await Self.locator([listed]).locate(.claude, override: own.path) == .found(own, .override))
    }

    /// **A path the reader named that is not a program is said so**, never passed over for another: they named it
    /// because the one we would find is not the one they mean.
    @Test func anOverrideThatIsNotAProgramIsUnusableAndNothingElseIsTried() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        let listed = scratch.appending("bin")
        _ = try Self.install("claude", in: listed)
        let notExecutable = try Self.install("claude", in: scratch.appending("own"), executable: false)
        let missing = scratch.appending("nowhere/claude").path
        let directory = scratch.appending("bin").path
        for path in [notExecutable.path, missing, directory] {
            #expect(await Self.locator([listed]).locate(.claude, override: path) == .overrideUnusable(path: path))
        }
    }

    @Test func theFirstDirectoryHoldingTheProgramWins() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        let first = scratch.appending("first"), second = scratch.appending("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let found = try Self.install("codex", in: second)
        _ = try Self.install("codex", in: scratch.appending("third"))
        #expect(await Self.locator([first, second, scratch.appending("third")]).locate(.codex, override: nil)
                == .found(found, .searchDirectory))
    }

    /// A file that cannot be run, and a directory with the program's name, are not the program.
    @Test func aFileThatCannotRunOrADirectoryIsPassedOver() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        _ = try Self.install("claude", in: scratch.appending("plain"), executable: false)
        try FileManager.default.createDirectory(at: scratch.appending("folder/claude"), withIntermediateDirectories: true)
        let real = try Self.install("claude", in: scratch.appending("real"))
        #expect(await Self.locator([scratch.appending("plain"), scratch.appending("folder"), scratch.appending("real")])
            .locate(.claude, override: nil) == .found(real, .searchDirectory))
    }

    /// **The login shell's answer is read for a path to a program of that name and nothing else** — a profile can
    /// print anything, and `command -v` answers an alias with its definition.
    @Test func aLoginShellIsAskedLastAndOnlyAPathToTheProgramIsTaken() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        let program = try Self.install("claude", in: scratch.appending("nvm/bin"))
        let decoy = try Self.install("other", in: scratch.appending("decoy"))
        let shell = try FakeCLI.shell(printing: [
            "Welcome back!", decoy.path, "alias claude='claude --bare'", "claude", program.path, "",
        ])
        #expect(await Self.locator([scratch.appending("empty")], shell: shell.executable)
            .locate(.claude, override: nil) == .found(program, .loginShell))
    }

    @Test func aLoginShellThatNamesNothingRunnableFindsNothing() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        let notExecutable = try Self.install("claude", in: scratch.appending("bin"), executable: false)
        let shell = try FakeCLI.shell(printing: ["claude not found", notExecutable.path, "relative/claude"])
        #expect(await Self.locator([], shell: shell.executable).locate(.claude, override: nil) == .notFound)
    }

    /// A profile that hangs — waiting on a prompt, say — is ended at the bound and finds nothing.
    @Test func aLoginShellThatHangsIsEndedAtTheBound() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        let program = try Self.install("claude", in: scratch.appending("bin"))
        let shell = try FakeCLI.shell(printing: [program.path], sleep: 30)
        let start = ContinuousClock.now
        #expect(await Self.locator([], shell: shell.executable, timeout: .milliseconds(500))
            .locate(.claude, override: nil) == .notFound)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    // MARK: - What the reader must do

    @Test func whereNothingWasFoundTheReaderIsToldWhatToDo() throws {
        let program = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        #expect(CLIReadiness(.notFound) == .notInstalled)
        #expect(CLIReadiness(.overrideUnusable(path: "/tmp/x")) == .overrideUnusable(path: "/tmp/x"))
        #expect(CLIReadiness(.found(program, .searchDirectory)) == nil, "found: the preflight decides")
    }

    @Test func aVersionIsReadFromWhatEachCLIPrints() {
        #expect(CLIVersion.parse("2.1.294 (Claude Code)\n") == "2.1.294")
        #expect(CLIVersion.parse("codex-cli 0.161.0\n") == "0.161.0")
        #expect(CLIVersion.parse("warning: something\ncodex-cli 0.161.0-alpha.3") == "0.161.0-alpha.3")
        #expect(CLIVersion.parse("no version here") == nil)
        #expect(CLIVersion.parse("") == nil)
    }

    @Test func whatAnOlderCLISaysIsReadAsTooOld() {
        #expect(CLIDiagnosis.saysTooOld("error: unknown option '--tools'\n"))
        #expect(CLIDiagnosis.saysTooOld("error: unexpected argument '--listen' found\n\nUsage: codex app-server"))
        #expect(!CLIDiagnosis.saysTooOld("Error: stdin is not a terminal"))
        #expect(!CLIDiagnosis.saysTooOld(""))
    }
}
