import Foundation
import FoundationModels

/// What the app asks the model service. Typed and `Codable`, the way it asks the dictionary service
/// — rather than an app-side `LanguageModelExecutor` forwarding over XPC, which would carry
/// `Transcript` and streaming events across the boundary for nothing this protocol lacks.
public enum ModelRequest: Codable, Sendable, Equatable {
    /// Which of a numbered list of senses the word carries in a sentence.
    case pickSense(SenseQuestion)
    /// The reader's sentence, in the reader's language.
    case translate(TranslationQuestion)
    /// How the word is being used in the reader's sentence, in prose. **Asked of this model and
    /// not Apple's**: the LLM panes must work for a reader without Apple Intelligence, which is
    /// most of mainland China, and an explanation that only some readers get is a pane that reads
    /// as broken to the rest.
    case explain(SentenceQuestion)
    /// Load the model and compile what the first answer would, so that answer does not pay for it.
    /// The first call measured 1.6–2.5 s cold against 0.24–0.44 s warm.
    case prewarm
    /// What is installed, whether it is loaded, and whether this process can run MLX at all.
    case status
    /// End the service. Unloading *is* ending it: MLX gives its memory back promptly, but the OS
    /// returns the process's pages lazily — measured 54 to 798 MB left after an in-process unload.
    case unload
}

/// A sense question, as the model sees it. **Numbered, never keyed**: the model answers with a
/// position in this list, and the app maps it back — so nothing the model says can name a sense
/// that is not in the list.
public struct SenseQuestion: Codable, Sendable, Equatable {
    public let sentence: String
    /// How the word is used in the sentence, where the tagger committed. Said in the prompt.
    public let partOfSpeech: String?
    /// The senses' texts, in the order the answer will be read against.
    public let senses: [String]

    public init(sentence: String, partOfSpeech: String?, senses: [String]) {
        self.sentence = sentence
        self.partOfSpeech = partOfSpeech
        self.senses = senses
    }
}

/// A sentence to translate, and what is known about the word the reader stopped at.
///
/// **The chosen sense goes with it.** A translation pane run apart from the sense mark renders two
/// subsystems side by side that can disagree while both look certain; fed the sense, Qwen sharpened
/// 船舱 to 货舱 in every run that had it. The sense's text is the publisher's, and it may go to this
/// model only because the model runs on this Mac — the same boundary `ExplainerTier` draws.
public struct TranslationQuestion: Codable, Sendable, Equatable {
    /// The word the reader met and what it meant — **one value, because half of it is useless**:
    /// a sense with no word to attach it to was silently dropped, and the pane then rendered an
    /// unguided translation as though it had been told the sense.
    public struct MetSense: Codable, Sendable, Equatable {
        public let term: String
        /// The text of the sense the reader met — tapped, or marked by the selector.
        public let sense: String

        public init(term: String, sense: String) {
            self.term = term
            self.sense = sense
        }
    }

    public let sentence: String
    /// BCP-47, the reader's own language: "zh-Hans".
    public let target: String
    public let met: MetSense?

    public init(sentence: String, target: String, met: MetSense? = nil) {
        self.sentence = sentence
        self.target = target
        self.met = met
    }
}

public enum ModelReply: Codable, Sendable, Equatable {
    /// The number the model chose: 0 for "none clearly fits", otherwise a position in the list.
    /// **Not yet checked against the list** — that is the caller's job, because it holds the list.
    case sense(Int)
    case translation(String)
    case explanation(String)
    case prewarmed
    case status(ModelServiceStatus)
    case unloading
    case failure(ModelFailure)
}

/// Why the service did not answer. A value, not a dropped connection, so the app can tell "there is
/// no model here" from "the model declined this".
public enum ModelFailure: Error, Codable, Sendable, Equatable {
    /// Nothing is downloaded — or nothing whole is.
    case notInstalled
    /// Installed, and it does not fit in what is free right now. Decided before loading.
    case insufficientMemory(needed: UInt64, available: UInt64)
    /// The model declined the request. Its own abstention, never folded into "not here".
    case refused
    /// The model could not answer this request — its weights failed to load on first use, or the
    /// generation itself failed. The two are one case because the backend loads lazily inside the
    /// first generation, and the service cannot tell them apart without guessing.
    case generationFailed(String)
    case invalidRequest(String)
}

/// What the service reports about itself.
public struct ModelServiceStatus: Codable, Sendable, Equatable {
    /// The size it would load, where one is installed whole.
    public let installed: LocalModelSize?
    public let loaded: Bool
    /// One MLX op evaluated on the GPU, in this process — nil where it failed. "The service runs"
    /// and "the service can run MLX" are different claims: without the Metal library in the right
    /// place the service starts, gets a device, and dies on its first array.
    public let gpu: String?
    /// The process's footprint, in bytes — nil where the kernel would not say, which is not zero.
    public let footprint: UInt64?
    /// What sizing reads before loading.
    public let availableMemory: UInt64?

    public init(installed: LocalModelSize?, loaded: Bool, gpu: String?, footprint: UInt64?, availableMemory: UInt64?) {
        self.installed = installed
        self.loaded = loaded
        self.gpu = gpu
        self.footprint = footprint
        self.availableMemory = availableMemory
    }
}


/// How long ending the service may take, **in one place because the two sides have to agree**.
///
/// The service, asked to unload, stops admitting work and waits for what is in flight; the client
/// waits for the reply and then for the process to go. A client bound shorter than the service's own
/// wait makes a service doing exactly what it was asked read as a failure — and the app then says
/// answers may still be coming from the model it just replaced, when nothing was wrong.
public enum ModelShutdown: Sendable {
    /// What the service gives work already in flight before it ends itself.
    public static let drain = Duration.seconds(30)
    /// What the client gives the whole request. Longer than the drain, by the margin an XPC
    /// round trip needs.
    public static let ask = drain + .seconds(5)
    /// What the client then gives the process to go. The service replies first and exits a moment
    /// later, so this is short by design.
    public static let processExit = Duration.seconds(5)
}
