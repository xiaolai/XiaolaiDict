import Foundation
import ModelKit
import os
import XiaolaiDictBase

/// **The reader's own `claude`, kept running and asked one question at a time** (ADR-0053, plan §5).
///
/// Started with the lean flags measured on 2026-10-09 (plan §1) in an empty directory: none of the reader's settings,
/// hooks, MCP servers, slash commands or tools reach the session, and nothing is written to their session history.
/// **Never `--bare`**, which reads no OAuth and so cannot use a subscription. The CLI is the reader's, unmodified, and
/// signs itself in; nothing here reads what it keeps.
///
/// Measured resident on `haiku`: 0.6–0.9 s to the first token, 0.9–1.1 s to the whole answer, 243–245 MB. A new
/// process is warm about two seconds after it starts with nothing asked of it (0.77 s for a first question asked six
/// seconds after the start, against 2.6 s asked at once), so a replacement needs no warm-up turn.
///
/// The CLI takes no temperature and no token budget; `GenerationRequest`'s are not sent. An answer's length is the
/// instructions' to bound.
public final class ClaudeCLIProvider: TextGenerating {
    private let model: String
    private let executable: URL
    private let session: ResidentSession<ClaudeCLIWire>

    /// A provider for the `claude` at `executable`, started with `model` in `workingDirectory` — which must be empty and
    /// the app's own (`ScratchDirectory`): the CLI reads instructions from the directory it runs in — with `searchPath`
    /// as its `PATH` where the locator named one (`CLILocator.searchPath`).
    public convenience init(executable: URL, model: String, workingDirectory: URL, searchPath: String? = nil,
                            configuration: ResidentConfiguration = .standard) {
        self.init(executable: executable, model: model, workingDirectory: workingDirectory, searchPath: searchPath,
                  configuration: configuration, events: { _ in })
    }

    init(executable: URL, model: String, workingDirectory: URL, searchPath: String? = nil,
         configuration: ResidentConfiguration, events: @escaping @Sendable (ResidentEvent) -> Void) {
        self.model = model
        self.executable = executable
        session = ResidentSession(
            wire: ClaudeCLIWire(launch: ChildLaunch(executable: executable, arguments: Self.arguments(model: model),
                                                   workingDirectory: workingDirectory, searchPath: searchPath)),
            configuration: configuration, events: events)
    }

    public func generate(_ request: GenerationRequest) async throws(ProviderFailure) -> String {
        // The reader's text, and so refused where the CLI could read it as a flag — before anything is started.
        guard Self.acceptsModelName(model) else { throw .modelNotFound }
        return try await session.ask(request)
    }

    /// **What the reader must do before this CLI can answer**: one trivial question, its time, and the CLI's version.
    /// The process it starts is kept, warm, for the questions that follow.
    public func preflight() async -> CLIReadiness {
        guard Self.acceptsModelName(model) else { return .unavailable(.modelNotFound) }
        return await CLIPreflight.readiness(of: executable, asking: session)
    }

    /// Puts the process away and waits for it to end. For the app's quit; dropping the provider ends it too.
    public func shutDown() async {
        await session.shutDown()
    }

    /// **The lean flags** (plan §1), in this order, with the reader's model and the resident system prompt.
    static func arguments(model: String) -> [String] {
        [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--model", model, "--no-session-persistence", "--tools", "", "--disable-slash-commands",
            "--setting-sources", "", "--strict-mcp-config", "--system-prompt", ResidentTurn.systemPrompt,
        ]
    }

    /// Whether `name` can be a model's name: an alias (`haiku`), an id (`claude-haiku-4-5`), a context suffix
    /// (`sonnet[1m]`) or a cloud id (`us.anthropic.…:0`) — and nothing that starts with a dash or holds a space.
    static func acceptsModelName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.properties.isAlphabetic || ("0"..."9").contains(first)
        else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (Self.modelCharacters.contains($0)) }
    }

    private static let modelCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:[]/@"))

    var residentPID: Int32? {
        get async { await session.residentPID }
    }
}

/// **Claude's `stream-json`**: one `user` message in; lines out until the turn's `result` — a `system`/`init` line on
/// the first, an `assistant` line, a `rate_limit_event`, and others this does not need, all passed over.
///
/// A failure is read from the `assistant` line's `error` — a kind, such as `authentication_failed` (nobody signed in)
/// or `model_not_found`, measured 2026-10-09 — and from the `result`'s status where there is none. **The CLI's own
/// words are never read**: they are prose, they change, and they can echo the question.
struct ClaudeCLIWire: ResidentWire {
    struct Conversation: Sendable {}

    private static var log: Logger { Logger(subsystem: XiaolaiDictIdentity.app, category: "providers") }

    let launch: ChildLaunch

    func open(_ child: ChildProcess) async throws(ProviderFailure) -> Conversation {
        Conversation()
    }

    func ask(_ request: GenerationRequest, in conversation: Conversation, over child: ChildProcess)
        async throws(ProviderFailure) -> Result<String, ProviderFailure> {
        try await child.send(try Self.userMessage(ResidentTurn.text(for: request)))
        var reported: ProviderFailure?
        while true {
            let line = try await child.nextLine()
            guard !line.isEmpty else { continue }
            guard let event = try? JSONDecoder().decode(StreamEvent.self, from: line) else {
                Self.log.error("claude wrote a line that is not stream-json; passed over")
                continue
            }
            switch event.type {
            case "assistant":
                if let kind = event.error { reported = reported ?? Self.failure(forError: kind) }
                if event.message?.stopReason == "refusal" { reported = .refused }
            case "result":
                return Self.outcome(of: event, reported: reported)
            default:
                continue
            }
        }
    }

    /// What a `result` line means, given what the turn's `assistant` line reported. **Success is said, never assumed**:
    /// a result whose `is_error` is missing or not a boolean is not an answer, since the text beside it may be an error.
    static func outcome(of result: StreamEvent, reported: ProviderFailure?) -> Result<String, ProviderFailure> {
        if result.stopReason == "refusal" { return .failure(.refused) }
        if let reported { return .failure(reported) }
        guard let isError = result.isError else {
            return .failure(.badShape("a result that does not say whether it failed"))
        }
        if isError { return .failure(failure(forStatus: result.apiErrorStatus)) }
        let answer = (result.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? .failure(.badShape("an empty answer")) : .success(answer)
    }

    /// The `assistant` line's `error` kind. A kind this does not know is a backend that did not answer.
    static func failure(forError kind: String) -> ProviderFailure {
        switch kind {
        case "authentication_failed", "billing_error": .unauthorised
        case "model_not_found": .modelNotFound
        case "rate_limit": .rateLimited
        case "invalid_request": .badShape("a request the CLI refused")
        default: .unreachable
        }
    }

    /// An erroring `result` with no `assistant` error, by the API's status where the CLI gives one.
    static func failure(forStatus status: Int?) -> ProviderFailure {
        switch status {
        case 401, 403: .unauthorised
        case 404: .modelNotFound
        case 429: .rateLimited
        case .some(500..<600): .unreachable
        default: .badShape("the CLI reported an error")
        }
    }

    static func userMessage(_ text: String) throws(ProviderFailure) -> Data {
        do {
            return try JSONEncoder().encode(UserLine(message: .init(content: text)))
        } catch {
            throw .badShape("a question that would not encode")
        }
    }

    private struct UserLine: Encodable {
        struct Message: Encodable {
            let role = "user"
            let content: String
        }

        let type = "user"
        let message: Message
    }

    /// The fields of a `stream-json` line this reads. **Each is read on its own and an unreadable one is absent**, so a
    /// field of an unexpected shape in a later CLI costs that field, never the line — a `result` passed over as not
    /// JSON would hold the turn until its deadline.
    struct StreamEvent: Decodable {
        struct Message: Decodable {
            let stopReason: String?

            enum CodingKeys: String, CodingKey { case stopReason = "stop_reason" }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                stopReason = try? container.decodeIfPresent(String.self, forKey: .stopReason)
            }
        }

        let type: String
        let error: String?
        let isError: Bool?
        let result: String?
        let stopReason: String?
        let apiErrorStatus: Int?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case type, error, result, message
            case isError = "is_error"
            case stopReason = "stop_reason"
            case apiErrorStatus = "api_error_status"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            error = try? container.decodeIfPresent(String.self, forKey: .error)
            isError = try? container.decodeIfPresent(Bool.self, forKey: .isError)
            result = try? container.decodeIfPresent(String.self, forKey: .result)
            stopReason = try? container.decodeIfPresent(String.self, forKey: .stopReason)
            apiErrorStatus = try? container.decodeIfPresent(Int.self, forKey: .apiErrorStatus)
            message = try? container.decodeIfPresent(Message.self, forKey: .message)
        }
    }
}
