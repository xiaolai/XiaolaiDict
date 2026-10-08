import Foundation

/// **The OpenAI-compatible `/chat/completions` wire, as much of it as this app speaks** — `Codable` types, so the
/// request is built and the answer read by the coders and never by hand (and `JSONSerialization` stays the
/// instruments' alone, `InstrumentSerialisationTests`).
///
/// Every decoder here is **lenient field by field**: a server that writes one field another way loses that field and
/// keeps the rest, because "OpenAI-compatible" covers servers that each agree with OpenAI about different things.
enum ChatCompletionsWire {
    /// The name the token budget is sent under. OpenAI's newer models refuse `max_tokens`, and many other servers do
    /// not know `max_completion_tokens` — so the provider starts with the new name, and a 400 that names the one it
    /// sent moves it to the other, once.
    enum TokenField: String, Sendable, Equatable {
        case maxCompletionTokens = "max_completion_tokens"
        case maxTokens = "max_tokens"

        var other: TokenField { self == .maxCompletionTokens ? .maxTokens : .maxCompletionTokens }
    }

    struct Message: Encodable, Equatable {
        let role: String
        let content: String
    }

    /// The request body: the model, a system message where there are instructions, the user's message, the
    /// temperature, and the token budget under `field`'s name. Not streamed (plan §5): the lookup path's answers are
    /// whole strings.
    struct Request: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let field: TokenField

        init(model: String, generation: GenerationRequest, field: TokenField) {
            self.model = model
            var messages: [Message] = []
            if !generation.instructions.isEmpty { messages.append(Message(role: "system", content: generation.instructions)) }
            messages.append(Message(role: "user", content: generation.prompt))
            self.messages = messages
            temperature = generation.temperature
            maxTokens = generation.maxTokens
            self.field = field
        }

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ name: String) { stringValue = name }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(model, forKey: Key("model"))
            try container.encode(messages, forKey: Key("messages"))
            try container.encode(temperature, forKey: Key("temperature"))
            try container.encode(maxTokens, forKey: Key(field.rawValue))
        }
    }

    /// A completion: the first choice is the answer.
    struct Completion: Decodable {
        let choices: [Choice]
    }

    struct Choice: Decodable {
        let message: AnswerMessage?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try? container.decodeIfPresent(AnswerMessage.self, forKey: .message)
            finishReason = try? container.decodeIfPresent(String.self, forKey: .finishReason)
        }
    }

    struct AnswerMessage: Decodable {
        /// The answer's text — a string, or the text parts of an array, joined; nil where there is neither.
        let content: String?
        /// OpenAI's refusal field: present, and not empty, where the model declined.
        let refusal: String?

        enum CodingKeys: String, CodingKey {
            case content, refusal
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            refusal = try? container.decodeIfPresent(String.self, forKey: .refusal)
            if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
                content = text
            } else if let parts = try? container.decodeIfPresent([ContentPart].self, forKey: .content) {
                content = parts.compactMap(\.text).joined()
            } else {
                content = nil
            }
        }
    }

    /// One part of a content array. Only text parts are read; an image part has no `text` and adds nothing.
    struct ContentPart: Decodable {
        let text: String?

        enum CodingKeys: String, CodingKey {
            case type, text
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try? container.decodeIfPresent(String.self, forKey: .type)
            let text = try? container.decodeIfPresent(String.self, forKey: .text)
            self.text = type == nil || type == "text" ? text : nil
        }
    }

    /// An error body, read only to decide a failure's kind — **never quoted anywhere**. OpenAI writes
    /// `{"error":{"message","type","param","code"}}`; other servers write `{"error":"…"}`, `{"message":"…"}` or a
    /// FastAPI `detail`, which may be a list echoing the request and is deliberately not read as a message.
    struct ErrorBody: Decodable {
        let message: String?
        let parameter: String?
        let code: String?

        private enum CodingKeys: String, CodingKey {
            case error, message
        }

        private enum DetailKeys: String, CodingKey {
            case message, param, code
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let detail = try? container.nestedContainer(keyedBy: DetailKeys.self, forKey: .error) {
                message = try? detail.decodeIfPresent(String.self, forKey: .message)
                parameter = try? detail.decodeIfPresent(String.self, forKey: .param)
                code = (try? detail.decodeIfPresent(String.self, forKey: .code))
                    ?? (try? detail.decodeIfPresent(Int.self, forKey: .code)).map { String($0) }
            } else {
                message = (try? container.decodeIfPresent(String.self, forKey: .error))
                    ?? (try? container.decodeIfPresent(String.self, forKey: .message))
                parameter = nil
                code = nil
            }
        }

        /// Whether this error is the server refusing the token budget's name `field` — by the parameter it names,
        /// or by a message that names it. A message naming the *other* name as the one to use still names this one
        /// as refused: OpenAI's says "'max_tokens' is not supported … Use 'max_completion_tokens' instead."
        func refuses(_ field: TokenField) -> Bool {
            if parameter == field.rawValue { return true }
            guard let message else { return false }
            return message.contains(field.rawValue) && !message.contains("Use '\(field.rawValue)'")
        }
    }
}
