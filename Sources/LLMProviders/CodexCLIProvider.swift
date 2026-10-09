import Foundation
import ModelKit
import os
import XiaolaiDictBase

/// **The reader's own `codex app-server`, kept running with one reused thread** (ADR-0053, plan §5).
///
/// Measured on 0.161.0 (plan §10, 2026-10-09): a thread's first turn costs 7–8 s and later ones 1.9–3.7 s, so a
/// process opens one ephemeral thread and warms it with a trivial turn before any question; a thread cannot be forked
/// from an ephemeral one ("no rollout found"), and forking a saved one costs 4–5 s a turn and writes to the reader's
/// Codex history, so each question is a turn on the warm thread, prefaced as unrelated (`ResidentTurn`).
///
/// **Isolation, as far as it goes.** `isolation` turns off the reader's hooks — two ran on every turn without it —
/// plugins, apps and the tools a dictionary question has no use for; each MCP server the reader configured is disabled
/// for the thread by name, the names asked of the server (`config/read`) — `-c mcp_servers={}` merges and removes
/// nothing. **The reader's global `AGENTS.md` cannot be kept out**: neither `project_doc_max_bytes=0` nor an empty
/// `instructions` removes it from the thread's instruction sources (measured). It is the reader's own text going to
/// their own provider.
///
/// The model is the reader's, where they named one, else the server's default entry from `model/list` — never a name
/// written into this build — at `low` effort. The server takes no temperature and no token budget; they are not sent.
public final class CodexCLIProvider: TextGenerating {
    private let executable: URL
    private let session: ResidentSession<CodexCLIWire>

    /// A provider for the `codex` at `executable`, asking `model` — empty for the server's default — in
    /// `workingDirectory`, which must be empty and the app's own (`ScratchDirectory`), with `searchPath` as its `PATH`
    /// where the locator named one.
    public convenience init(executable: URL, model: String, workingDirectory: URL, searchPath: String? = nil,
                            configuration: ResidentConfiguration = .standard) {
        self.init(executable: executable, model: model, workingDirectory: workingDirectory, searchPath: searchPath,
                  configuration: configuration, events: { _ in })
    }

    init(executable: URL, model: String, workingDirectory: URL, searchPath: String? = nil,
         configuration: ResidentConfiguration, events: @escaping @Sendable (ResidentEvent) -> Void) {
        self.executable = executable
        session = ResidentSession(
            wire: CodexCLIWire(launch: ChildLaunch(executable: executable, arguments: Self.arguments,
                                                  workingDirectory: workingDirectory, searchPath: searchPath),
                               model: model.trimmingCharacters(in: .whitespacesAndNewlines)),
            configuration: configuration, events: events)
    }

    public func generate(_ request: GenerationRequest) async throws(ProviderFailure) -> String {
        try await session.ask(request)
    }

    /// **What the reader must do before this CLI can answer**: one trivial question, its time, and the CLI's version.
    /// The process it starts is kept, warm, for the questions that follow.
    public func preflight() async -> CLIReadiness {
        await CLIPreflight.readiness(of: executable, asking: session)
    }

    /// Puts the process away and waits for it to end. For the app's quit; dropping the provider ends it too.
    public func shutDown() async {
        await session.shutDown()
    }

    /// **The `-c` overrides that keep the reader's Codex setup out of a dictionary question**, each accepted by
    /// 0.161.0 with no configuration warning (measured 2026-10-09). Hooks, plugins and apps are the measured leaks;
    /// the rest turn off tools and context a one-line answer has no use for.
    static let isolation = [
        "features.hooks=false", "features.plugins=false", "features.apps=false", "features.memories=false",
        "features.multi_agent=false", "features.shell_tool=false", "features.unified_exec=false",
        "features.image_generation=false", "features.browser_use=false", "features.computer_use=false",
        "features.skill_search=false", "features.goals=false", "features.tool_suggest=false",
        "web_search=\"disabled\"", "include_environment_context=false", "include_permissions_instructions=false",
        "include_apps_instructions=false", "skills.include_instructions=false",
    ]

    static let arguments = ["app-server", "--listen", "stdio://"] + isolation.flatMap { ["-c", $0] }

    var residentPID: Int32? {
        get async { await session.residentPID }
    }
}

/// **`codex app-server`'s JSON-RPC over standard input and output**, one ephemeral thread per process.
///
/// Opening: `initialize` and `initialized`; `account/read` — nobody signed in is unauthorised, and no thread is
/// started; `config/read` for the MCP servers' names; `model/list` where the reader named no model; `thread/start`,
/// ephemeral, read-only, never asking for approval, the servers disabled; one warm-up turn. A question: `turn/start`,
/// then the thread's `item/agentMessage/delta`s and `item/completed`s until its `turn/completed` — read by message, and
/// answered by the final one (`TurnTranscript`). A request the server makes of this client is refused at once.
struct CodexCLIWire: ResidentWire {
    struct Conversation: Sendable {
        let thread: String
    }

    typealias RPC = CodexAppServer

    /// The failure a request the server has no method for reads as — a server older than this client.
    static let methodNotFound = "a method the server does not have"

    /// The turn a new thread is warmed with: its first turn is the slow one (7–8 s measured).
    static let warmUp = GenerationRequest(instructions: "", prompt: "Reply with the single word: ready",
                                          maxTokens: 8, temperature: 0)

    private static var log: Logger { Logger(subsystem: XiaolaiDictIdentity.app, category: "providers") }
    private static let ids = OSAllocatedUnfairLock(initialState: 0)

    let launch: ChildLaunch
    /// The reader's model, or empty for the server's default.
    let model: String

    func open(_ child: ChildProcess) async throws(ProviderFailure) -> Conversation {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        _ = try await call("initialize", RPC.InitializeParams(
            clientInfo: .init(name: "xiaolaidict", title: nil, version: version)),
            returning: RPC.Empty.self, over: child).get()
        try await child.send(try Self.encode(RPC.Notification(method: "initialized")))
        let account = try await call("account/read", RPC.Empty(), returning: RPC.AccountRead.self,
                                     over: child).get()
        guard account.account != nil || account.requiresOpenaiAuth == false else { throw .unauthorised }
        let config = try await call("config/read", RPC.ConfigReadParams(cwd: launch.workingDirectory.path),
                                    returning: RPC.ConfigRead.self, over: child).get()
        let servers = (config.config.mcpServers ?? [:]).keys.sorted()
        let model = model.isEmpty ? try await defaultModel(over: child) : model
        let started = try await call("thread/start", RPC.ThreadStartParams(
            cwd: launch.workingDirectory.path, model: model, baseInstructions: ResidentTurn.systemPrompt,
            config: servers.isEmpty ? nil
                : ["mcp_servers": Dictionary(uniqueKeysWithValues: servers.map { ($0, ["enabled": false]) })]),
            returning: RPC.ThreadStarted.self, over: child).get()
        let conversation = Conversation(thread: started.thread.id)
        _ = try await turn(Self.warmUp, in: conversation, over: child).get()
        return conversation
    }

    func ask(_ request: GenerationRequest, in conversation: Conversation, over child: ChildProcess)
        async throws(ProviderFailure) -> Result<String, ProviderFailure> {
        try await turn(request, in: conversation, over: child)
    }

    // MARK: - A turn

    private func turn(_ request: GenerationRequest, in conversation: Conversation, over child: ChildProcess)
        async throws(ProviderFailure) -> Result<String, ProviderFailure> {
        let id = Self.nextID()
        try await child.send(try Self.encode(RPC.Request(id: id, method: "turn/start", params: RPC.TurnStartParams(
            threadId: conversation.thread, input: [.init(text: ResidentTurn.text(for: request))]))))
        var turn: String?
        var transcripts = TurnTranscripts()
        while true {
            switch try await Self.read(over: child) {
            case .response(.number(id), let line, let error):
                if let error { return .failure(Self.failure(for: error)) }
                // Without the turn's id its end cannot be recognised, and the turn may still be running.
                guard let started = Self.decode(RPC.Response<RPC.TurnStarted>.self, line) else {
                    throw .badShape("an answer this client cannot read")
                }
                turn = started.result.turn.id
            case .response:
                continue
            case .notification("item/agentMessage/delta", let line):
                guard let delta = Self.decode(RPC.Incoming<RPC.AgentMessageDelta>.self, line)?.params,
                      delta.threadId == conversation.thread else { continue }
                try transcripts.update(delta.turnId) { transcript throws(ProviderFailure) in
                    try transcript.add(delta.delta, to: delta.itemId ?? "")
                }
            case .notification("item/completed", let line):
                guard let done = Self.decode(RPC.Incoming<RPC.ItemCompleted>.self, line)?.params,
                      done.threadId == conversation.thread, done.item.type == "agentMessage" else { continue }
                try transcripts.update(done.turnId) { transcript throws(ProviderFailure) in
                    try transcript.complete(done.item)
                }
            case .notification("error", let line):
                guard let note = Self.decode(RPC.Incoming<RPC.ErrorNotification>.self, line)?.params,
                      note.threadId == conversation.thread, !note.willRetry else { continue }
                try transcripts.update(note.turnId) { transcript throws(ProviderFailure) in
                    transcript.reported = transcript.reported ?? Self.failure(for: note.error.codexErrorInfo)
                }
            case .notification("turn/completed", let line):
                guard let done = Self.decode(RPC.Incoming<RPC.TurnCompleted>.self, line)?.params,
                      done.threadId == conversation.thread else { continue }
                try transcripts.update(done.turn.id) { transcript throws(ProviderFailure) in
                    transcript.finished = done.turn
                }
            case .notification:
                continue
            }
            // The end is recognised once both are known, in whichever order they came.
            if let turn, let transcript = transcripts[turn], let done = transcript.finished {
                return Self.outcome(of: done, transcript: transcript)
            }
        }
    }

    /// What a completed turn means: its answer (`TurnTranscript.answer`), or the failure that ended it.
    static func outcome(of turn: RPC.TurnCompleted.Turn, transcript: TurnTranscript) -> Result<String, ProviderFailure> {
        switch turn.status {
        case "completed":
            let answer = transcript.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? .failure(.badShape("an empty answer")) : .success(answer)
        case "failed":
            return .failure(transcript.reported ?? failure(for: turn.error?.codexErrorInfo))
        default:
            // Interrupted, by nobody here: the server did not answer.
            return .failure(.unreachable)
        }
    }

    /// A turn's `codexErrorInfo` as a kind. One this does not know is a backend that did not answer.
    static func failure(for kind: RPC.ErrorKind?) -> ProviderFailure {
        switch kind?.name {
        case "usageLimitExceeded", "rateLimitExceeded", "sessionBudgetExceeded": .rateLimited
        case "unauthorized": .unauthorised
        case "cyberPolicy", "misalignmentPolicyViolation": .refused
        case "contextWindowExceeded": .badShape("a question longer than the model's context")
        case "badRequest": .badShape("a request the server refused")
        default: .unreachable
        }
    }

    static func failure(for error: RPC.RPCError) -> ProviderFailure {
        error.code == RPC.RPCError.methodNotFound ? .badShape(methodNotFound)
            : .badShape("a request the server refused")
    }

    // MARK: - Requests

    /// The model the server lists as its default, or nil — the server's own choice — where it lists none.
    private func defaultModel(over child: ChildProcess) async throws(ProviderFailure) -> String? {
        try await call("model/list", RPC.Empty(), returning: RPC.ModelList.self, over: child).get()
            .data.first { $0.isDefault == true }?.id
    }

    /// Sends a request and reads to its response: the result, or the error the server answered with — which leaves the
    /// conversation intact. A throw is a stream that broke.
    private func call<Params: Encodable, Answer: Decodable>(
        _ method: String, _ params: Params, returning _: Answer.Type, over child: ChildProcess
    ) async throws(ProviderFailure) -> Result<Answer, ProviderFailure> {
        let id = Self.nextID()
        try await child.send(try Self.encode(RPC.Request(id: id, method: method, params: params)))
        while true {
            guard case .response(.number(id), let line, let error) = try await Self.read(over: child) else { continue }
            if let error { return .failure(Self.failure(for: error)) }
            guard let response = Self.decode(RPC.Response<Answer>.self, line) else {
                throw .badShape("an answer this client cannot read")
            }
            return .success(response.result)
        }
    }

    private enum Line {
        case response(RPC.RequestID, Data, RPC.RPCError?)
        case notification(String, Data)
    }

    /// The next response or notification. A request from the server is refused here, and a line that is not
    /// JSON-RPC is passed over.
    private static func read(over child: ChildProcess) async throws(ProviderFailure) -> Line {
        while true {
            let line = try await child.nextLine()
            guard !line.isEmpty else { continue }
            guard let envelope = decode(RPC.Envelope.self, line) else {
                log.error("codex wrote a line that is not JSON-RPC; passed over")
                continue
            }
            switch (envelope.id, envelope.method) {
            case (let id?, let method?):
                log.info("refused a request codex made of this client: \(method, privacy: .public)")
                try await child.send(try encode(RPC.Refusal(id: id)))
            case (nil, let method?):
                return .notification(method, line)
            case (let id?, nil):
                return .response(id, line, envelope.error)
            case (nil, nil):
                log.error("codex wrote a JSON-RPC line with neither an id nor a method; passed over")
            }
        }
    }

    private static func nextID() -> Int {
        ids.withLock { id in
            id += 1
            return id
        }
    }

    private static func encode(_ value: some Encodable) throws(ProviderFailure) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .badShape("a request that would not encode")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ line: Data) -> T? {
        try? JSONDecoder().decode(type, from: line)
    }
}

/// **What one turn has written, kept apart by message and bounded** (0.161.0's schema): each agent message's deltas under
/// its item, in the order the messages began; what `item/completed` said each was in the end — its whole text and its
/// `phase`; a failure the server reported; and the turn's own end.
///
/// **The answer is one message, never all of them run together**: the last that says it is the `final_answer`; where
/// none says — a model that gives no phase — the last that is not `commentary`; and the last of all where every one
/// is. A message's completed text where the server completed it, its deltas where it did not. Where nothing was
/// streamed, the completed turn's own list, read the same way.
///
/// **Bounded like an endpoint's answer** (`OpenAICompatibleProvider.responseByteLimit`), the deltas and the completed
/// texts each, and in the messages kept apart: past either a turn is not an answer, and the wire's throw ends the
/// process — what it writes next could not be read as the start of anything.
struct TurnTranscript {
    struct Message {
        var deltas = ""
        var text: String?
        var phase: String?
    }

    private(set) var order: [String] = []
    private(set) var messages: [String: Message] = [:]
    private var deltaBytes = 0
    private var textBytes = 0
    var reported: ProviderFailure?
    var finished: CodexAppServer.TurnCompleted.Turn?

    static let byteLimit = OpenAICompatibleProvider.responseByteLimit
    /// Far more than a dictionary question's turn writes — a narration and an answer — and short of a stream of them.
    static let messageLimit = 64

    static let tooLarge = ProviderFailure.badShape("an answer larger than the bound")

    mutating func add(_ delta: String, to item: String) throws(ProviderFailure) {
        try admit(item)
        deltaBytes += delta.utf8.count
        guard deltaBytes <= Self.byteLimit else { throw Self.tooLarge }
        messages[item, default: Message()].deltas += delta
    }

    mutating func complete(_ item: CodexAppServer.TurnCompleted.Turn.Item) throws(ProviderFailure) {
        let id = item.id ?? ""
        try admit(id)
        textBytes += item.text?.utf8.count ?? 0
        guard textBytes <= Self.byteLimit else { throw Self.tooLarge }
        messages[id, default: Message()].text = item.text ?? ""
        messages[id, default: Message()].phase = item.phase
    }

    private mutating func admit(_ item: String) throws(ProviderFailure) {
        guard messages[item] == nil else { return }
        guard order.count < Self.messageLimit else { throw Self.tooLarge }
        order.append(item)
        messages[item] = Message()
    }

    var answer: String {
        let written = order.compactMap { messages[$0] }.map { (text: $0.text ?? $0.deltas, phase: $0.phase) }
        if let chosen = Self.choose(written) { return chosen }
        let listed = (finished?.items ?? []).filter { $0.type == "agentMessage" }
        return Self.choose(listed.map { (text: $0.text ?? "", phase: $0.phase) }) ?? ""
    }

    private static func choose(_ messages: [(text: String, phase: String?)]) -> String? {
        messages.last { $0.phase == "final_answer" }?.text
            ?? messages.last { $0.phase != "commentary" }?.text
            ?? messages.last?.text
    }
}

/// A turn's transcript by its id, **bounded in turns too**: one turn is asked at a time, and notifications naming a
/// handful of others are a server out of step, not a reason to keep everything it says.
struct TurnTranscripts {
    private var transcripts: [String: TurnTranscript] = [:]

    static let turnLimit = 4

    subscript(turn: String) -> TurnTranscript? { transcripts[turn] }

    mutating func update(_ turn: String,
                         _ change: (inout TurnTranscript) throws(ProviderFailure) -> Void) throws(ProviderFailure) {
        if transcripts[turn] == nil {
            guard transcripts.count < Self.turnLimit else { throw TurnTranscript.tooLarge }
            transcripts[turn] = TurnTranscript()
        }
        try change(&transcripts[turn, default: TurnTranscript()])
    }
}
