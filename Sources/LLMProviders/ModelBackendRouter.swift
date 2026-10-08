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

/// **The one place a question is sent to a source** (ADR-0053, plan §2): the bundled model, or the provider the reader
/// chose — read from their settings at every question, so a question never goes to a source they have left.
///
/// - **The three ladders do not change.** Each is handed `ask`, which has `ModelClient.ask`'s shape once its reply is
///   taken: `nil` and every failure fall through to Apple's rung and the embedding floor.
/// - **One provider at a time, and a source the reader leaves is put away before the next is used**: a CLI's process
///   is ended and waited for, never left to outlive the choice that started it. So is everything at `shutDown`, which
///   the app awaits before it quits.
/// - **Built once per choice**, however many questions arrive while it is being built.
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

    /// A router over the reader's choice and settings, read through `choices` and `settings` — stores over the suite
    /// the app was given, handed in rather than the suite itself, which may not cross into this actor.
    public init(choices: ProviderChoiceStore, settings: ProviderSettingsStore, local: Local,
                factory: ProviderFactory = .standard) {
        self.init(source: { ProviderSource(choice: choices.load(), settings: settings.load()) }, local: local,
                  factory: factory, client: { ProviderClient(provider: $0, tier: $1) })
    }

    /// The same over a source of the caller's, and with the flip as an argument.
    init(source: @escaping @Sendable () -> ProviderSource, local: Local, factory: ProviderFactory,
         dictionaryTextMayLeave: Bool) {
        self.init(source: source, local: local, factory: factory, client: {
            ProviderClient(provider: $0, tier: $1, dictionaryTextMayLeave: dictionaryTextMayLeave)
        })
    }

    private init(source: @escaping @Sendable () -> ProviderSource, local: Local, factory: ProviderFactory,
                 client: @escaping @Sendable (any TextGenerating, ProviderTier) -> ProviderClient) {
        self.local = local
        self.source = source
        self.factory = factory
        self.client = client
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
        let source = currentSource
        guard source != .local else {
            await settle(on: .local)
            return RoutedReply(reply: await local.ask(request), tier: .onThisMac)
        }
        // A source that could not be made answers nothing, which the ladders read as a backend that is not here.
        let reply = await settle(on: source)?.client?.ask(request, origin: origin)
        return RoutedReply(reply: reply, tier: source.tier)
    }

    /// What a lookup does beside the dictionaries: loads the local model where it is the source. Nothing else.
    public func prewarmForLookup() async {
        guard currentSource == .local else { return }
        await local.prewarm()
    }

    /// **Brings the source up to the reader's settings** — at launch, and when they change. A source they have left is
    /// put away; a resident CLI they have chosen is started and asked one trivial question, once for that choice, so
    /// their first real one is warm. Answers what that question said, or nil where nothing was asked.
    @discardableResult
    public func reconcile() async -> ProviderReadiness? {
        guard let held = await settle(on: currentSource) else { return nil }
        guard let backend = held.build.backend else { return held.build.refusal }
        // Taken before the question is awaited, so a second reconcile arriving meanwhile does not ask it again.
        guard backend.warmsByAsking, warmed != held.making else { return nil }
        warmed = held.making
        return await check()
    }

    /// **What the chosen source says when asked one trivial question** — always asked, an endpoint too. Nil where the
    /// source is the local model, which `--model-status` asks.
    public func check() async -> ProviderReadiness? {
        guard let held = await settle(on: currentSource) else { return nil }
        guard let backend = held.build.backend else { return held.build.refusal }
        return await backend.readiness()
    }

    /// The source the settings name now.
    public var currentSource: ProviderSource { source() }

    /// Puts every provider away and returns once each has gone — the app's quit. Nothing is started after it.
    public func shutDown() async {
        closed = true
        await settle(on: .local)
    }

    // MARK: - Holding one source

    /// **The source `wanted`, made once and held — and whatever was held before it, put away first.**
    ///
    /// The slot is moved on before anything is awaited, so a question arriving meanwhile waits for the same making
    /// instead of starting a second; and the source left is put away — its process ended and seen to end — before the
    /// one wanted is used. Nil for the local source, which is not a provider, and for a making overtaken by a later
    /// change, whose source is no longer the reader's.
    @discardableResult
    private func settle(on wanted: ProviderSource) async -> Held? {
        switch slot {
        case .made(let held) where held.source == wanted: return held
        case .making(let source, _, let task) where source == wanted: return current(await task.value)
        case .empty where wanted == .local: return nil
        default: break
        }
        let left = slot
        if wanted == .local || closed {
            slot = .empty
            await Self.putAway(left)
            return nil
        }
        makings += 1
        let factory = factory, client = client, id = makings
        // Unstructured on purpose: a question that started the making and then gave up must not cancel it for the
        // others waiting on it — and it is not left behind, because the next change puts away whatever it made.
        let making = Task {
            let build = await factory.make(wanted)
            return Held(making: id, source: wanted, build: build, client: build.backend.map { client($0, wanted.tier) })
        }
        slot = .making(wanted, id, making)
        await Self.putAway(left)
        let held = await making.value
        if case .making(_, let now, _) = slot, now == id { slot = .made(held) }
        return current(held)
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
    private static func putAway(_ slot: Slot) async {
        let held: Held
        switch slot {
        case .empty: return
        case .made(let made): held = made
        case .making(_, _, let task): held = await task.value
        }
        guard let backend = held.build.backend else { return }
        log.info("putting away the language-model source the reader left")
        await backend.shutDown()
    }
}
