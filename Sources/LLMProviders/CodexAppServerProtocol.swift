import Foundation

/// **The part of `codex app-server`'s JSON-RPC this app speaks**, as `codex app-server generate-ts` describes it for
/// 0.161.0 (2026-10-09). Messages carry no `jsonrpc` member — the server sends none and needs none (measured).
///
/// Every type reads only the fields it needs, so a field the server adds costs nothing, and some it sends are never
/// read on purpose: `account/read` answers with the reader's email, and `config/read` with their whole configuration —
/// an MCP server's environment can hold a key. Of those this keeps whether there is an account and the servers' names.
enum CodexAppServer {
    /// A request's id: this client's are integers, the server's may be strings.
    enum RequestID: Codable, Sendable, Equatable {
        case number(Int)
        case text(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let number): try container.encode(number)
            case .text(let text): try container.encode(text)
            }
        }
    }

    /// What every incoming line is first read as: a response (an id and no method), a notification (a method and no
    /// id), or a request from the server (both).
    struct Envelope: Decodable {
        let id: RequestID?
        let method: String?
        let error: RPCError?
    }

    struct RPCError: Codable, Sendable, Equatable {
        let code: Int
        let message: String

        /// JSON-RPC's "method not found" — what a server older than a method answers.
        static let methodNotFound = -32601
    }

    struct Request<Params: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: Params
    }

    struct Notification: Encodable {
        let method: String
    }

    /// The answer this client gives every request the server makes of it: it supports none. An approval asked for and
    /// never answered would hold the turn until its deadline.
    struct Refusal: Encodable {
        let id: RequestID
        let error = RPCError(code: RPCError.methodNotFound, message: "not supported by this client")
    }

    struct Response<Result: Decodable>: Decodable {
        let result: Result
    }

    struct Incoming<Params: Decodable>: Decodable {
        let params: Params
    }

    struct Empty: Codable {}

    // MARK: - The handshake

    struct InitializeParams: Encodable {
        struct ClientInfo: Encodable {
            let name: String
            let title: String?
            let version: String

            enum CodingKeys: String, CodingKey { case name, title, version }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                // Written as null rather than left out: the schema has it required and nullable.
                try container.encode(title, forKey: .title)
                try container.encode(version, forKey: .version)
            }
        }

        struct Capabilities: Encodable {
            let experimentalApi = false
            let requestAttestation = false
        }

        let clientInfo: ClientInfo
        let capabilities = Capabilities()
    }

    /// Whether anyone is signed in. **The account's fields are never read** — it carries the reader's email.
    struct AccountRead: Decodable {
        struct Present: Decodable {}

        let account: Present?
        let requiresOpenaiAuth: Bool?
    }

    struct ConfigReadParams: Encodable {
        let cwd: String
    }

    /// The names of the MCP servers the reader configured, **and nothing else of their configuration**.
    struct ConfigRead: Decodable {
        struct Config: Decodable {
            let mcpServers: [String: Unread]?

            enum CodingKeys: String, CodingKey { case mcpServers = "mcp_servers" }
        }

        /// A value read past and kept nowhere.
        struct Unread: Decodable {
            init(from decoder: any Decoder) throws {}
        }

        let config: Config
    }

    struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
            let isDefault: Bool?
        }

        let data: [Model]
    }

    struct ThreadStartParams: Encodable {
        let cwd: String
        let ephemeral = true
        let approvalPolicy = "never"
        let sandbox = "read-only"
        let model: String?
        let baseInstructions: String
        let config: [String: [String: [String: Bool]]]?
    }

    struct ThreadStarted: Decodable {
        struct Thread: Decodable {
            let id: String
        }

        let thread: Thread
    }

    // MARK: - A turn

    struct TurnStartParams: Encodable {
        struct Input: Encodable {
            let type = "text"
            let text: String
            let textElements: [String] = []

            enum CodingKeys: String, CodingKey {
                case type, text
                case textElements = "text_elements"
            }
        }

        let threadId: String
        let input: [Input]
        let effort = "low"
    }

    struct TurnStarted: Decodable {
        let turn: TurnReference
    }

    struct TurnReference: Decodable {
        let id: String
    }

    /// A piece of one agent message's text. **Keyed by its item**: a turn can write more than one message — a
    /// `commentary` before its `final_answer` — and their deltas interleave with nothing else to tell them apart.
    struct AgentMessageDelta: Decodable {
        let threadId: String
        let turnId: String
        /// Nil where a server leaves it out; such deltas are read as one message.
        let itemId: String?
        let delta: String
    }

    /// An item the turn finished writing — for an agent message, its whole text and its phase.
    struct ItemCompleted: Decodable {
        let item: TurnCompleted.Turn.Item
        let threadId: String
        let turnId: String
    }

    struct TurnCompleted: Decodable {
        struct Turn: Decodable {
            /// A thread item, of which only an agent message is read: its id, its text, and its `phase` —
            /// `commentary` or `final_answer`, or absent where the model does not say (the schema's own caveat).
            struct Item: Decodable {
                let type: String
                let id: String?
                let text: String?
                let phase: String?

                enum CodingKeys: String, CodingKey { case type, id, text, phase }

                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    type = try container.decode(String.self, forKey: .type)
                    id = try? container.decodeIfPresent(String.self, forKey: .id)
                    text = try? container.decodeIfPresent(String.self, forKey: .text)
                    phase = try? container.decodeIfPresent(String.self, forKey: .phase)
                }
            }

            let id: String
            let status: String
            let items: [Item]?
            let error: TurnError?
        }

        let threadId: String
        let turn: Turn
    }

    struct TurnError: Decodable {
        let codexErrorInfo: ErrorKind?
    }

    struct ErrorNotification: Decodable {
        let error: TurnError
        let willRetry: Bool
        let threadId: String
        let turnId: String
    }

    /// `codexErrorInfo`: a name (`"usageLimitExceeded"`), or an object whose one key is the name
    /// (`{"httpConnectionFailed": {…}}`). Only the name is kept.
    struct ErrorKind: Decodable, Equatable {
        let name: String

        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }

            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name
            } else {
                self.name = try decoder.container(keyedBy: AnyKey.self).allKeys.first?.stringValue ?? ""
            }
        }
    }
}
