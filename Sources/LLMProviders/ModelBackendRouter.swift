import Foundation
import ModelKit
import os
import XiaolaiDictBase

/// An answer, and where the question went to get it.
public struct RoutedReply: Sendable, Equatable {
    public let reply: ModelReply?
    /// The tier of the source that was asked: on this Mac for the local model and a loopback endpoint, remote for the
    /// rest. What the panes' provenance says is read from this, never assumed.
    public let tier: ProviderTier

    public init(reply: ModelReply?, tier: ProviderTier) {
        self.reply = reply
        self.tier = tier
    }
}

/// What the router did with a source, in order — for its log, and for a test asserting the order.
enum RouterEvent: Sendable, Equatable {
    /// A source the reader left began to be put away.
    case leaving(ProviderSource)
    /// …and has gone.
    case left(ProviderSource)
    /// A source began to be made.
    case making(ProviderSource)
    /// The app's quit began.
    case closing
    /// …and every source has gone.
    case closed
}

/// **The one place a question is sent to a source** (ADR-0053, plan §2): the bundled model, or the provider the reader
/// chose — read from their settings at every question, so a question never goes to a source they have left.
///
/// - **The three ladders do not change.** Each is handed `ask`, which has `ModelClient.ask`'s shape once its reply is
///   taken: `nil` and every failure fall through to Apple's rung and the embedding floor.
/// - **One provider at a time, and a source the reader leaves is put away before the next is made or anything is
///   asked**: a CLI's process is ended and waited for, never left to outlive the choice that started it. The putting
///   away is one chain (`retiring`), each source after the one before, and **everything awaits all of it** — the
///   making of the next source, a question to any source, the local model's too, and `shutDown`, which the app awaits
///   before it quits. No caller can be handed a source while the one before it is still running.
/// - **Built once per choice**, however many questions arrive while it is being built — and **the choice is read again
///   once it is built**: a source the reader left while it was being made, with nothing else to notice, is not asked;
///   the question goes to the one they chose instead.
/// - **Warmed when chosen, never by a lookup.** A resident CLI is asked one trivial question at launch and when it is
///   chosen (`reconcile`); an endpoint is asked nothing until a reader's question, which opens its connection. A
///   lookup prewarms only the local model, because a lookup that started a CLI would spend the reader's subscription
///   on a pane they may never open.
public actor ModelBackendRouter {
    /// The bundled model, as the app reaches it: through `LocalModelAccess`, which answers "not installed" without
    /// starting anything where there is no model.
    public struct Local: Sendable {
        public let ask: @Sendable (ModelRequest) async -> ModelReply?
        public let prewarm: @Sendable () async -> Void

        public init(ask: @escaping @Sendable (ModelRequest) async -> ModelReply?,
                    prewarm: @escaping @Sendable () async -> Void) {
            self.ask = ask
            self.prewarm = prewarm
        }
    }

    private let local: Local
    private let source: @Sendable () -> ProviderSource
    private let factory: ProviderFactory
    /// How a made provider is wrapped: by `ProviderClient`'s own public initialiser, under the owner's constant — or,
    /// for a test of the flip, with the constant as an argument.
    private let client: @Sendable (any TextGenerating, ProviderTier) -> ProviderClient
    private let events: @Sendable (RouterEvent) -> Void

    /// A router over the reader's choice and settings, read through `choices` and `settings` — stores over the suite
    /// the app was given, handed in rather than the suite itself, which may not cross into this actor.
    public init(choices: ProviderChoiceStore, settings: ProviderSettingsStore, local: Local,
                factory: ProviderFactory = .standard) {
        self.init(source: { ProviderSource(choice: choices.load(), settings: settings.load()) }, local: local,
                  factory: factory, client: { ProviderClient(provider: $0, tier: $1) })
    }

    /// The same over a source of the caller's, with the flip as an argument, and what it does reported to `events`.
    init(source: @escaping @Sendable () -> ProviderSource, local: Local, factory: ProviderFactory,
         dictionaryTextMayLeave: Bool, events: @escaping @Sendable (RouterEvent) -> Void = { _ in }) {
        self.init(source: source, local: local, factory: factory, client: {
            ProviderClient(provider: $0, tier: $1, dictionaryTextMayLeave: dictionaryTextMayLeave)
        }, events: events)
    }

    private init(source: @escaping @Sendable () -> ProviderSource, local: Local, factory: ProviderFactory,
                 client: @escaping @Sendable (any TextGenerating, ProviderTier) -> ProviderClient,
                 events: @escaping @Sendable (RouterEvent) -> Void = { _ in }) {
        self.local = local
        self.source = source
        self.factory = factory
        self.client = client
        self.events = events
    }

    /// A source made ready, kept while it is the reader's choice. **Known by its making, never by its source**: a source
    /// left and chosen again is made again, and the first one is put away — so two of one source are two things.
    private struct Held: Sendable {
        let making: Int
        let source: ProviderSource
        let build: ProviderBuild
        let client: ProviderClient?
    }

    /// What the router holds: nothing, a source being made — which making — or a source made.
    private enum Slot {
        case empty
        case making(ProviderSource, Int, Task<Held, Never>)
        case made(Held)
    }

    private var slot = Slot.empty
    private var makings = 0
    /// **Every source left, being put away one after another** — the last of the chain, which awaits the one before. A
    /// making awaits it before it makes anything, and a question or a quit that finds nothing held awaits it too.
    private var retiring: Task<Void, Never>?
    /// The making `reconcile` has warmed, or is warming. **Once per choice**: the app reconciles at every write to its
    /// suite — window frames among them — and a CLI asked its trivial question each time would spend the reader's
    /// subscription on nothing.
    private var warmed: Int?
    /// Set by `shutDown`: the app is quitting, and a question that arrives meanwhile must not start a process nothing
    /// will be left to end. The local model still answers.
    private var closed = false

    private static var log: Logger { Logger(subsystem: XiaolaiDictIdentity.app, category: "providers") }

    /// Asks the source the reader has chosen, read now, `request` — asked for `origin`.
    public func ask(_ request: ModelRequest, origin: QuestionOrigin) async -> RoutedReply {
        guard let (source, held) = await settleOnCurrentSource() else {
            return RoutedReply(reply: nil, tier: currentSource.tier)
        }
        guard source != .local else { return RoutedReply(reply: await local.ask(request), tier: .onThisMac) }
        // A source that could not be made answers nothing, which the ladders read as a backend that is not here.
        let reply = await held?.client?.ask(request, origin: origin)
        return RoutedReply(reply: reply, tier: source.tier)
    }

    /// What a lookup does beside the dictionaries: loads the local model where it is the source. Nothing else — but
    /// only once a provider the reader left has gone, as for a question.
    public func prewarmForLookup() async {
        guard currentSource == .local else { return }
        await settle(on: .local)
        await local.prewarm()
    }

    /// **Brings the source up to the reader's settings** — at launch, and when they change. A source they have left is
    /// put away; a resident CLI they have chosen is started and asked one trivial question, once for that choice, so
    /// their first real one is warm. Answers what that question said, or why the source could not be made — with the
    /// source it is about — or nil where nothing was asked.
    @discardableResult
    public func reconcile() async -> SourceReadiness? {
        guard let held = await settleOnCurrentSource()?.held else { return nil }
        guard let backend = held.build.backend else { return Self.readiness(held.build.refusal, of: held) }
        // Taken before the question is awaited, so a second reconcile arriving meanwhile does not ask it again.
        guard backend.warmsByAsking, warmed != held.making else { return nil }
        warmed = held.making
        return Self.readiness(await backend.readiness(), of: held)
    }

    /// **What the chosen source says when asked one trivial question** — always asked, an endpoint too — and which
    /// source said it. Nil where the source is the local model, which `--model-status` asks.
    public func check() async -> SourceReadiness? {
        guard let held = await settleOnCurrentSource()?.held else { return nil }
        guard let backend = held.build.backend else { return Self.readiness(held.build.refusal, of: held) }
        return Self.readiness(await backend.readiness(), of: held)
    }

    /// `readiness`, said of the source `held` was made for.
    private static func readiness(_ readiness: ProviderReadiness?, of held: Held) -> SourceReadiness? {
        readiness.map { SourceReadiness(source: held.source, readiness: $0) }
    }

    /// The source the settings name now.
    public var currentSource: ProviderSource { source() }

    /// Puts every provider away and returns once each has gone — the app's quit. Nothing is started after it.
    public func shutDown() async {
        events(.closing)
        closed = true
        await settle(on: .local)
        events(.closed)
    }

    // MARK: - Holding one source

    /// **The source the settings name, made and held, read again once it is** — so nothing is asked of a source the
    /// reader left while it was being made. Read up to `rereads` times; a reader whose choice changes every time it is
    /// read is asked nothing, and nil says so. The local source answers with no `Held`.
    private func settleOnCurrentSource() async -> (source: ProviderSource, held: Held?)? {
        for _ in 0..<Self.rereads {
            let source = currentSource
            let held = await settle(on: source)
            if currentSource == source { return (source, held) }
            Self.log.info("the reader's language-model source changed while it was being made; reading it again")
        }
        return nil
    }

    private static let rereads = 3

    /// **The source `wanted`, made once and held — and whatever was held before it, put away first.**
    ///
    /// The slot is moved on before anything is awaited, so a question arriving meanwhile waits for the same making
    /// instead of starting a second. The source left joins the chain of sources being put away, and **the making awaits
    /// the whole chain before it makes anything**, so whoever waits for the making — every question that wants it — waits
    /// for the source before it to have gone. Nil for the local source, which is not a provider, once the chain has run
    /// out; and for a making overtaken by a later change, whose source is no longer the reader's.
    @discardableResult
    private func settle(on wanted: ProviderSource) async -> Held? {
        switch slot {
        // Made after every source before it had gone, and nothing has been left since.
        case .made(let held) where held.source == wanted: return held
        case .making(let source, _, let task) where source == wanted: return current(await task.value)
        case .empty where wanted == .local:
            await retiring?.value
            return nil
        default: break
        }
        let retirement = retire(slot)
        if wanted == .local || closed {
            slot = .empty
            await retirement.value
            return nil
        }
        makings += 1
        let factory = factory, client = client, id = makings, events = events
        // Unstructured on purpose: a question that started the making and then gave up must not cancel it for the
        // others waiting on it — and it is not left behind, because the next change puts away whatever it made.
        let making = Task {
            await retirement.value
            events(.making(wanted))
            let build = await factory.make(wanted)
            return Held(making: id, source: wanted, build: build, client: build.backend.map { client($0, wanted.tier) })
        }
        slot = .making(wanted, id, making)
        let held = await making.value
        if case .making(_, let now, _) = slot, now == id { slot = .made(held) }
        return current(held)
    }

    /// Adds what `left` held to the chain of sources being put away, after everything already in it, and answers the
    /// chain as it now ends.
    private func retire(_ left: Slot) -> Task<Void, Never> {
        let before = retiring, events = events
        let retirement = Task {
            await before?.value
            await Self.putAway(left, events)
        }
        retiring = retirement
        return retirement
    }

    /// `held`, while it is still the making held — nil once a later change has moved on and is putting it away, even
    /// where the reader has since chosen the same source again: that is another making.
    private func current(_ held: Held) -> Held? {
        if case .made(let now) = slot, now.making == held.making { return held }
        if case .making(_, let now, _) = slot, now == held.making { return held }
        return nil
    }

    /// Puts away what `slot` held, and returns once it has gone: a source being made is waited for first, so what it
    /// started is put away too rather than left running for nobody.
    private static func putAway(_ slot: Slot, _ events: @Sendable (RouterEvent) -> Void) async {
        let held: Held
        switch slot {
        case .empty: return
        case .made(let made): held = made
        case .making(_, _, let task): held = await task.value
        }
        guard let backend = held.build.backend else { return }
        log.info("putting away the language-model source the reader left")
        events(.leaving(held.source))
        await backend.shutDown()
        events(.left(held.source))
    }
}
