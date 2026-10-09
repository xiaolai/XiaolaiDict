import Foundation
@testable import LLMProviders
import Synchronization
import Testing
import XiaolaiDictTestSupport

/// **A stand-in for the reader's CLI**: a small Python script in a directory of the test's own, which speaks the wire
/// the real one speaks and does what the question tells it to.
///
/// Nothing here starts the reader's `claude` or `codex`, reaches a network or reads a credential. Each fake writes
/// what it was started with and what it received to `log`, one JSON object a line, so a test asserts the wire — the
/// arguments, the directory, the requests — and not only the answer.
///
/// **A question steers the fake with markers in its text**: `[[slow:0.5]]` sleeps first, `[[silent]]` never answers,
/// `[[crash]]` exits mid-turn, `[[garbage]]` writes a line that is not JSON first, `[[overlong]]` writes a line past
/// `ChildProcess.lineLimit`, `[[echo:X]]` puts X in the answer. Each fake's own markers are listed in its script.
/// The answer names the process (`pid=…`), so a test can tell a reused process from a new one.
struct FakeCLI: Sendable {
    let directory: TemporaryDirectory
    let executable: URL
    let log: URL

    /// The directory a resident CLI is started in: empty, the test's own, and removed with it.
    var workingDirectory: URL { directory.appending("work") }

    /// How the fake `claude` behaves before any question.
    enum ClaudeStartup: String {
        case normal
        /// Exits at once, before reading anything.
        case exitEarly = "exit-early"
        /// Refuses a flag the way an older `claude` refuses one it does not know, and exits.
        case unknownOption = "unknown-option"
        /// Answers every question the way `claude` answers when nobody signed in, then exits — measured 2026-10-09.
        case signedOut = "signed-out"
    }

    /// How the fake `codex app-server` behaves.
    enum CodexStartup: String {
        case normal
        case exitEarly = "exit-early"
        /// Refuses `--listen` the way an older `codex` refuses an argument it does not know.
        case unexpectedArgument = "unexpected-argument"
        /// Reports no account.
        case signedOut = "signed-out"
        /// Has no `thread/start`.
        case noThreadStart = "no-thread-start"
        /// Never answers its handshake: a server that hangs while it is being opened.
        case stall
        /// Opens the first time it is started, and every later process stalls in its handshake: a replacement that
        /// hangs while the first still answers.
        case stallAfterFirst = "stall-after-first"
    }

    static func claude(_ startup: ClaudeStartup = .normal) throws -> FakeCLI {
        try make(name: "claude", script: claudeScript, startup: startup.rawValue)
    }

    static func codex(_ startup: CodexStartup = .normal) throws -> FakeCLI {
        try make(name: "codex", script: codexScript, startup: startup.rawValue)
    }

    /// The fake `claude`, **run by an interpreter found on the `PATH`** — `#!/usr/bin/env <interpreter>` — as a CLI a
    /// package manager installs is (`#!/usr/bin/env node`). The interpreter, a shim for Python named `interpreter`, is
    /// written into `directory` — the fake's own where that is nil — which is on no `PATH` this process has.
    static func claude(runBy interpreter: String, in directory: URL? = nil) throws -> FakeCLI {
        let fake = try claude()
        let shim = (directory ?? fake.directory.url).appending(path: interpreter)
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexec /usr/bin/python3 -I \"$@\"\n".utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let script = try String(contentsOf: fake.executable, encoding: .utf8)
        let body = script.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[1]
        try Data("#!/usr/bin/env \(interpreter)\n\(body)".utf8).write(to: fake.executable)
        return fake
    }

    /// A login shell that ignores what it is asked, writes `lines` to standard output and exits — after sleeping
    /// `sleep` seconds, which a test sets past the locator's bound.
    static func shell(printing lines: [String], sleep: Double = 0) throws -> FakeCLI {
        let body = """
            #!/bin/sh
            sleep \(sleep)
            \(lines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "\n"))
            """
        let directory = TemporaryDirectory(named: "xiaolaidict-fake-shell")
        let executable = directory.appending("zsh")
        try Data(body.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return FakeCLI(directory: directory, executable: executable, log: directory.appending("log.jsonl"))
    }

    private static func make(name: String, script: String, startup: String) throws -> FakeCLI {
        let directory = TemporaryDirectory(named: "xiaolaidict-fake-\(name)")
        let executable = directory.appending(name)
        let log = directory.appending("log.jsonl")
        let body = script
            .replacingOccurrences(of: "@STARTUP@", with: startup)
            .replacingOccurrences(of: "@LOG@", with: log.path)
        try Data(body.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createDirectory(at: directory.appending("work"), withIntermediateDirectories: true)
        return FakeCLI(directory: directory, executable: executable, log: log)
    }

    /// `sink`, holding this fake — its script and its directories — for as long as whatever holds the sink: a session
    /// holds its events for its whole life, so a provider made with this can never outlive the program it starts.
    func holding(_ sink: @escaping @Sendable (ResidentEvent) -> Void) -> @Sendable (ResidentEvent) -> Void {
        { event in withExtendedLifetime(self) { sink(event) } }
    }

    /// Every object the fake logged, in order. A fake that logged nothing — never started — reads as none.
    func logged() throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    /// The values logged under `key`, in order.
    func logged<T>(_ key: String, as _: T.Type = T.self) throws -> [T] {
        try logged().compactMap { $0[key] as? T }
    }

    // MARK: - The scripts

    /// `claude -p --input-format stream-json --output-format stream-json`, as measured on 2.1.294 (2026-10-09): a
    /// `system`/`init` line on the first question, an `assistant` line, a `rate_limit_event`, and the turn's `result`.
    ///
    /// Its own markers: `[[error:KIND]]` answers with the assistant `error` KIND and an erroring result, as the real
    /// one does for `authentication_failed` and `model_not_found`; `[[status:N]]` an erroring result with
    /// `api_error_status` N and no assistant error; `[[refuse]]` a result whose stop reason is a refusal;
    /// `[[empty]]` an empty result; `[[exit-after]]` answers and then exits, as the real one does after an error.
    static let claudeScript = #"""
        #!/usr/bin/python3 -I
        import json, os, re, sys, time
        STARTUP = "@STARTUP@"
        LOG = "@LOG@"
        def log(obj):
            with open(LOG, "a") as f:
                f.write(json.dumps(obj) + "\n")
        def emit(obj):
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.stdout.flush()
        args = sys.argv[1:]
        if args == ["--version"]:
            print("9.9.9 (Fake Claude)")
            sys.exit(0)
        log({"argv": args, "pid": os.getpid(), "cwd": os.getcwd()})
        if STARTUP == "exit-early":
            sys.exit(3)
        if STARTUP == "unknown-option":
            sys.stderr.write("error: unknown option '--tools'\n")
            sys.exit(1)
        turn = 0
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            text = json.loads(line)["message"]["content"]
            turn += 1
            log({"turn": turn, "text": text, "pid": os.getpid()})
            marks = dict((m.group(1), m.group(2)) for m in re.finditer(r"\[\[([a-z-]+)(?::([^\]]*))?\]\]", text))
            if turn == 1:
                emit({"type": "system", "subtype": "init", "claude_code_version": "9.9.9", "tools": []})
            if STARTUP == "signed-out":
                emit({"type": "assistant", "error": "authentication_failed", "is_api_error_message": True,
                      "message": {"model": "<synthetic>", "content": [{"type": "text", "text": "Not logged in"}]}})
                emit({"type": "result", "subtype": "success", "is_error": True, "result": "Not logged in"})
                sys.exit(1)
            if "slow" in marks:
                time.sleep(float(marks["slow"]))
            if "silent" in marks:
                time.sleep(3600)
            if "crash" in marks:
                sys.exit(2)
            if "garbage" in marks:
                sys.stdout.write("this line is not JSON\n")
                sys.stdout.flush()
            if "overlong" in marks:
                sys.stdout.write("x" * (1 << 21) + "\n")
                sys.stdout.flush()
            if "error" in marks:
                emit({"type": "assistant", "error": marks["error"], "is_api_error_message": True,
                      "message": {"content": [{"type": "text", "text": "an error"}]}})
                emit({"type": "result", "subtype": "success", "is_error": True, "result": "an error"})
                continue
            if "status" in marks:
                emit({"type": "result", "subtype": "error_during_execution", "is_error": True,
                      "api_error_status": int(marks["status"]), "result": "an error"})
                continue
            answer = "pid=%d turn=%d echo=%s" % (os.getpid(), turn, marks.get("echo", ""))
            emit({"type": "assistant", "message": {"content": [{"type": "text", "text": answer}]}})
            emit({"type": "rate_limit_event", "rate_limit_info": {"status": "allowed"}})
            if "refuse" in marks:
                emit({"type": "result", "subtype": "success", "is_error": False, "stop_reason": "refusal",
                      "result": "I can't help with that."})
            elif "empty" in marks:
                emit({"type": "result", "subtype": "success", "is_error": False, "result": "  "})
            else:
                emit({"type": "result", "subtype": "success", "is_error": False, "stop_reason": "end_turn",
                      "result": "\n" + answer + "\n"})
            if "exit-after" in marks:
                sys.exit(0)
        """#

    /// `codex app-server --listen stdio://`, as its generated schema and a measured session describe it (0.161.0,
    /// 2026-10-09): `initialize`, `account/read`, `config/read`, `model/list`, `thread/start`, `turn/start` and its
    /// notifications. Two MCP servers are configured, one with a dot in its name and a secret in its environment.
    ///
    /// Its own markers: `[[fail:KIND]]` ends the turn failed with `codexErrorInfo` KIND (`[[fail:http]]` the object
    /// form) after an `error` notification that will not retry; `[[retrying]]` sends one that will, then answers;
    /// `[[approval]]` asks the client to approve a command first and logs the reply; `[[interrupt]]` ends the turn
    /// interrupted; `[[no-delta]]` answers in the completed turn's items alone.
    ///
    /// Each agent message is streamed as deltas carrying its `itemId` and then completed (`item/completed`) with its
    /// `phase`, as 0.161.0's schema has them — the answer `final_answer`. `[[commentary]]` writes a `commentary` message
    /// before the answer, as a model that narrates first does, and `[[commentary-after]]` one after it; `[[no-phase]]` completes the messages without a phase, as
    /// an older model does; `[[no-item-completed]]` sends no `item/completed`, so only the deltas say what was written;
    /// `[[flood]]` streams 320 KB of deltas into one message; `[[many-items]]` streams 300 messages of one word each.
    static let codexScript = #"""
        #!/usr/bin/python3 -I
        import json, os, re, sys, time
        STARTUP = "@STARTUP@"
        LOG = "@LOG@"
        def log(obj):
            with open(LOG, "a") as f:
                f.write(json.dumps(obj) + "\n")
        def emit(obj):
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.stdout.flush()
        def respond(rid, result):
            emit({"id": rid, "result": result})
        def note(method, params):
            emit({"method": method, "params": params})
        args = sys.argv[1:]
        if args == ["--version"]:
            print("codex-cli 9.9.9")
            sys.exit(0)
        log({"argv": args, "pid": os.getpid(), "cwd": os.getcwd()})
        if STARTUP == "exit-early":
            sys.exit(3)
        if STARTUP == "unexpected-argument":
            sys.stderr.write("error: unexpected argument '--listen' found\n")
            sys.exit(2)
        if STARTUP == "stall-after-first":
            try:
                os.close(os.open(LOG + ".first", os.O_CREAT | os.O_EXCL | os.O_WRONLY))
            except FileExistsError:
                STARTUP = "stall"
        if STARTUP == "stall":
            time.sleep(3600)
        threads, turns = 0, 0
        def read():
            line = sys.stdin.readline()
            if not line:
                sys.exit(0)
            return json.loads(line)
        while True:
            msg = read()
            method, rid, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
            log({"method": method, "params": params, "id": rid})
            if method == "initialize":
                respond(rid, {"userAgent": "xiaolaidict/9.9.9", "codexHome": "/nonexistent", "platformFamily": "unix",
                              "platformOs": "macos"})
            elif method == "initialized":
                pass
            elif method == "account/read":
                account = None if STARTUP == "signed-out" else {"type": "chatgpt", "email": "reader@example.com",
                                                                "planType": "plus"}
                respond(rid, {"account": account, "requiresOpenaiAuth": True})
            elif method == "config/read":
                respond(rid, {"config": {"model": "fake-configured", "mcp_servers": {
                    "alpha": {"command": "alpha-server", "env": {"ALPHA_TOKEN": "secret-value"}},
                    "beta.gamma": {"url": "https://example.invalid/mcp"}}}, "origins": {}, "layers": None})
            elif method == "model/list":
                respond(rid, {"data": [{"id": "fake-small", "model": "fake-small", "isDefault": False},
                                       {"id": "fake-default", "model": "fake-default", "isDefault": True}],
                              "nextCursor": None})
            elif method == "thread/start":
                if STARTUP == "no-thread-start":
                    emit({"id": rid, "error": {"code": -32601, "message": "unknown method thread/start"}})
                    continue
                threads += 1
                respond(rid, {"thread": {"id": "thread-%d-%d" % (os.getpid(), threads), "ephemeral": True},
                              "model": params.get("model") or "fake-configured"})
            elif method == "turn/start":
                turns += 1
                thread, turn = params["threadId"], "turn-%d" % turns
                text = params["input"][0]["text"]
                marks = dict((m.group(1), m.group(2)) for m in re.finditer(r"\[\[([a-z-]+)(?::([^\]]*))?\]\]", text))
                respond(rid, {"turn": {"id": turn, "status": "inProgress", "items": [], "error": None}})
                note("turn/started", {"threadId": thread, "turn": {"id": turn}})
                if "slow" in marks:
                    time.sleep(float(marks["slow"]))
                if "silent" in marks:
                    time.sleep(3600)
                if "crash" in marks:
                    sys.exit(2)
                if "garbage" in marks:
                    sys.stdout.write("this line is not JSON\n")
                    sys.stdout.flush()
                if "approval" in marks:
                    emit({"id": "approve-1", "method": "item/commandExecution/requestApproval",
                          "params": {"threadId": thread, "turnId": turn, "command": "ls"}})
                    log({"approvalReply": read()})
                if "fail" in marks:
                    kind = marks["fail"]
                    info = {"httpConnectionFailed": {"httpStatusCode": 502}} if kind == "http" else kind
                    error = {"message": "failed", "codexErrorInfo": info, "additionalDetails": None}
                    note("error", {"error": error, "willRetry": False, "threadId": thread, "turnId": turn})
                    note("turn/completed", {"threadId": thread, "turn": {"id": turn, "status": "failed", "items": [],
                                                                        "error": error}})
                    continue
                if "interrupt" in marks:
                    note("turn/completed", {"threadId": thread, "turn": {"id": turn, "status": "interrupted",
                                                                        "items": [], "error": None}})
                    continue
                if "retrying" in marks:
                    note("error", {"error": {"message": "reconnecting", "codexErrorInfo": "serverOverloaded"},
                                   "willRetry": True, "threadId": thread, "turnId": turn})
                answer = "pid=%d thread=%s turn=%d echo=%s" % (os.getpid(), thread, turns, marks.get("echo", ""))
                def message(item, text, phase):
                    for start in range(0, len(text), 5):
                        note("item/agentMessage/delta", {"threadId": thread, "turnId": turn, "itemId": item,
                                                         "delta": text[start:start + 5]})
                    if "no-item-completed" not in marks:
                        note("item/completed", {"threadId": thread, "turnId": turn, "completedAtMs": 0, "item": {
                            "type": "agentMessage", "id": item, "text": text,
                            "phase": None if "no-phase" in marks else phase}})
                if "flood" in marks:
                    for _ in range(5):
                        note("item/agentMessage/delta", {"threadId": thread, "turnId": turn, "itemId": "m",
                                                         "delta": "x" * 65536})
                if "many-items" in marks:
                    for n in range(300):
                        note("item/agentMessage/delta", {"threadId": thread, "turnId": turn, "itemId": "i%d" % n,
                                                         "delta": "word "})
                if "no-delta" not in marks:
                    note("item/agentMessage/delta", {"threadId": "another-thread", "turnId": turn, "itemId": "x",
                                                     "delta": "not this thread's "})
                    if "commentary" in marks:
                        message("c", "Let me look at the sentence first. ", "commentary")
                    message("m", answer, "final_answer")
                    if "commentary-after" in marks:
                        message("d", "That should settle it.", "commentary")
                items = [{"type": "agentMessage", "id": "m", "text": answer}] if "no-delta" in marks else []
                note("turn/completed", {"threadId": thread, "turn": {"id": turn, "status": "completed", "items": items,
                                                                    "error": None}})
            elif rid is not None:
                emit({"id": rid, "error": {"code": -32601, "message": "unknown method"}})
        """#
}

/// **Whether a process is still there** — `kill(pid, 0)` succeeds for a process that exists, and fails with `ESRCH` for
/// one that has gone and been reaped.
func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

/// Waits until `pid` has gone, up to `bound`. True if it went.
func waitUntilGone(_ pid: Int32, within bound: Duration = .seconds(5)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: bound)
    while isAlive(pid) {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// The `pid=…` an answer of a fake names.
func answeringPID(_ answer: String) throws -> Int32 {
    let field = try #require(answer.split(separator: " ").first { $0.hasPrefix("pid=") })
    return try #require(Int32(field.dropFirst("pid=".count)))
}

/// **An operation a test can stop waiting for.** A regression in a deadline or a cancellation makes the operation
/// hang rather than fail, and a test that awaited it would hang the whole run with it; this one records no outcome
/// past its bound, and the test fails on that instead.
final class Settling<T: Sendable>: Sendable {
    private final class Outcome: Sendable {
        let value = Mutex<Result<T, ProviderFailure>?>(nil)
    }

    private let outcome = Outcome()
    let task: Task<Void, Never>

    init(_ operation: @escaping @Sendable () async throws(ProviderFailure) -> T) {
        let outcome = outcome
        task = Task {
            do throws(ProviderFailure) {
                let value = try await operation()
                outcome.value.withLock { $0 = .success(value) }
            } catch {
                outcome.value.withLock { $0 = .failure(error) }
            }
        }
    }

    /// The outcome, once there is one, or nil if there is none by `bound`.
    func outcome(within bound: Duration = .seconds(10)) async -> Result<T, ProviderFailure>? {
        let deadline = ContinuousClock.now.advanced(by: bound)
        while ContinuousClock.now < deadline {
            if let settled = outcome.value.withLock({ $0 }) { return settled }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return outcome.value.withLock { $0 }
    }
}

/// What a session reported, in order, collected from whatever thread reported it.
final class EventLog: Sendable {
    private let events = Mutex<[ResidentEventRecord]>([])

    /// Whether each process the session had started was still running when a new one was spawned — the evidence
    /// that a replacement comes before the process it replaces is put away.
    func record(_ event: ResidentEvent) {
        events.withLock { recorded in
            let alive: [Int32: Bool]
            if case .spawned = event {
                alive = Dictionary(uniqueKeysWithValues: recorded.compactMap { record -> (Int32, Bool)? in
                    guard case .spawned(let pid) = record.event else { return nil }
                    return (pid, isAlive(pid))
                })
            } else {
                alive = [:]
            }
            recorded.append(ResidentEventRecord(event: event, aliveAtThisMoment: alive))
        }
    }

    var all: [ResidentEventRecord] { events.withLock { $0 } }

    var sink: @Sendable (ResidentEvent) -> Void { { [self] in record($0) } }

    /// Waits until an event matching `predicate` has been recorded, up to `bound`.
    func wait(within bound: Duration = .seconds(10), for predicate: (ResidentEvent) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: bound)
        while !all.contains(where: { predicate($0.event) }) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

struct ResidentEventRecord: Sendable {
    let event: ResidentEvent
    let aliveAtThisMoment: [Int32: Bool]
}
