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
        CLILocator(searchDirectories: directories, loginShell: shell.map { LoginShell(accountShell: $0.path) },
                   shellTimeout: timeout)
    }

    /// The order the plan names, and **the reader's own login shell** — the one their account names, which is the one
    /// whose profile sets their `PATH` — never anything a web page or a model said.
    @Test func theStandardSearchIsTheReadersOwnBinDirectoriesThenTheirLoginShell() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(CLILocator.standard.searchDirectories.map(\.path) == [
            home.appending(path: ".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
        ])
        let account = try #require(getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) })
        #expect(CLILocator.standard.loginShell == LoginShell(accountShell: account))
    }

    /// **The shell the account names, asked in its own syntax**: zsh, bash and the other POSIX shells as login and
    /// interactive shells, fish in fish's; a shell this cannot speak to — csh, which takes `-l` only alone — is not
    /// guessed at, and zsh, macOS's own, is asked instead. Each prints where the program is and then its `PATH`.
    @Test func eachLoginShellIsAskedInItsOwnSyntax() {
        for name in ["zsh", "bash", "sh", "ksh", "dash"] {
            let shell = LoginShell(accountShell: "/bin/\(name)")
            #expect(shell.executable.path == "/bin/\(name)")
            #expect(shell.arguments(for: .codex) == [
                "-l", "-i", "-c", "command -v codex; printf '%s%s\\n' '\(LoginShell.searchPathMarker)' \"$PATH\"",
            ])
        }
        let fish = LoginShell(accountShell: "/opt/homebrew/bin/fish")
        #expect(fish.executable.path == "/opt/homebrew/bin/fish")
        #expect(fish.arguments(for: .claude) == [
            "-l", "-i", "-c", "command -v claude; printf '%s%s\\n' '\(LoginShell.searchPathMarker)' (string join : $PATH)",
        ])
        for unknown in ["/bin/tcsh", "/bin/csh", "/usr/local/bin/nu", "", "relative/zsh"] {
            #expect(LoginShell(accountShell: unknown).executable.path == "/bin/zsh", "\(unknown)")
        }
        #expect(LoginShell(accountShell: nil).executable.path == "/bin/zsh")
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
            .locate(.claude, override: nil) == .found(program, .loginShell(searchPath: nil)))
    }

    /// **The `PATH` the login shell had is kept with what it found** — a CLI installed by a package manager is often a
    /// script whose interpreter is on that `PATH` and on no other this app has. Its own line, the last one printed, so
    /// a profile printing something like it earlier is not taken.
    @Test func theLoginShellsPathIsKeptWithWhatItFound() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        let program = try Self.install("claude", in: scratch.appending("nvm/bin"))
        let shell = try FakeCLI.shell(printing: [
            "\(LoginShell.searchPathMarker)/from/the/profile", program.path,
            "\(LoginShell.searchPathMarker)/Users/reader/.nvm/bin:/opt/homebrew/bin:/usr/bin",
        ])
        #expect(await Self.locator([], shell: shell.executable).locate(.claude, override: nil)
            == .found(program, .loginShell(searchPath: "/Users/reader/.nvm/bin:/opt/homebrew/bin:/usr/bin")))
    }

    /// **The `PATH` a found program runs with**: its own directory first — where an installer puts the interpreter a
    /// script names, `node` beside `claude` — then the login shell's, then the installers' directories, then this
    /// app's own; each once, and only absolute ones.
    @Test func aFoundProgramRunsWithItsOwnDirectoryAndTheLoginShellsPath() {
        let locator = Self.locator([URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")])
        let program = URL(fileURLWithPath: "/Users/reader/.nvm/versions/node/v22/bin/claude")
        let path = locator.searchPath(for: program, source: .loginShell(searchPath: "/a/bin:relative:/opt/homebrew/bin"),
                                      inherited: "/usr/bin:/bin:/a/bin")
        #expect(path == "/Users/reader/.nvm/versions/node/v22/bin:/a/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(locator.searchPath(for: program, source: .searchDirectory, inherited: nil)
                == "/Users/reader/.nvm/versions/node/v22/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    /// **A caller who gives up stops the shell**, rather than waiting out its bound: the probe ends, finds nothing, and
    /// the shell — and what its profile started — is gone.
    @Test func aCancelledLoginShellProbeEndsTheShell() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        let pidFile = scratch.appending("shell.pid")
        let shell = try FakeCLI.shell(printing: [])
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 3600\n".utf8).write(to: shell.executable)
        let locating = Settling { () async throws(ProviderFailure) in
            await Self.locator([], shell: shell.executable, timeout: .seconds(600)).locate(.claude, override: nil)
        }
        let pid = try await ChildProcessTests.descendant(writtenTo: pidFile)
        locating.task.cancel()
        #expect(await locating.outcome(within: .seconds(10)) == .success(.notFound),
                "the probe waited for its own bound after its caller gave up")
        #expect(await waitUntilGone(pid))
    }

    /// The same for the version a preflight reads: a CLI whose `--version` never answers is ended when its caller gives
    /// up, not when the probe's own bound passes.
    @Test func aCancelledVersionProbeEndsTheCLI() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-locator")
        let pidFile = scratch.appending("cli.pid")
        let cli = try Self.install("claude", in: scratch.appending("bin"))
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 3600\n".utf8).write(to: cli)
        let reading = Settling { () async throws(ProviderFailure) in
            await CLIVersion.read(cli, in: scratch.url, searchPath: nil, timeout: .seconds(600))
        }
        let pid = try await ChildProcessTests.descendant(writtenTo: pidFile)
        reading.task.cancel()
        #expect(await reading.outcome(within: .seconds(10)) == .success(nil),
                "the version probe waited for its own bound after its caller gave up")
        #expect(await waitUntilGone(pid))
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
        #expect(CLIReadiness(.found(program, .loginShell(searchPath: "/usr/bin"))) == nil)
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
