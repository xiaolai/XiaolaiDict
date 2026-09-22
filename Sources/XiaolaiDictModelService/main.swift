import Foundation
import FoundationModels
import LocalModel
import MLX
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Synchronization
// `#huggingFaceTokenizerLoader()` expands to a type that stores `any Tokenizer`, which the package
// does not mark `Sendable`; under Swift 6 that is an error inside the expansion, where it cannot be
// edited (the MLX-in-XPC spike, S4). Hence `@preconcurrency`.
@preconcurrency import Tokenizers
import XiaolaiDictCore
import XPC
import os

// The local model, alone in its own process (design: the local-model plan, §2). A GPU fault or an
// out-of-memory kill takes this service and not the app the reader is using — the same reason the
// private dictionary API lives behind its own boundary — and unloading is this process ending.
//
// Only XiaolaiDict may connect: the same team and XiaolaiDict's own signing identifier.

let log = Logger(subsystem: XiaolaiDictIdentity.modelService, category: "model")

/// A generation that will not end cannot be interrupted from outside: MLX's own loop honours
/// cancellation between tokens, but a wedged Metal call answers nothing and holds the model's memory
/// for as long as the process lives. Past this — far beyond the app's own 60 s prewarm deadline, and
/// a hundred times a normal answer — the process exits and launchd starts a clean one on the next
/// request. The same reasoning as the dictionary service's watchdog, for the same failure.
let watchdogLimit = Duration.seconds(300)

/// One MLX op, evaluated in this process on the GPU. "The service started" is not "the service can
/// run MLX": with the Metal library in the wrong place it starts, gets a device, and dies on its
/// first array (the MLX-in-XPC spike, S2) — which is why the bundle check asks this, not whether the
/// process is up.
func gpuCheck() -> String? {
    let doubled = MLXArray([1, 2, 3, 4] as [Int32]) * 2
    eval(doubled)
    guard doubled.asArray(Int32.self) == [2, 4, 6, 8] else { return nil }
    return "\(Device.defaultDevice())"
}

/// The model for an installed directory: loaded from that directory and nowhere else — no hub, no
/// downloader — with guided generation declared and reasoning not, which is what keeps Qwen3.5's
/// thinking off (measured: no `<think>` output and short answers in every run).
///
/// `FoundationModels.LanguageModel` by its full name: `MLXLMCommon` has a `LanguageModel` of its own
/// — a model architecture, not the protocol a session takes.
func mlxModel(at directory: URL, size: LocalModelSize) -> any FoundationModels.LanguageModel {
    log.notice("loading Qwen3.5 \(size.parameters, privacy: .public) from \(directory.lastPathComponent, privacy: .public)")
    return MLXLanguageModel(
        configuration: ModelConfiguration(directory: directory),
        capabilities: [.guidedGeneration],
        weightsLocation: { _ in directory },
        load: { _, _ in try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader()) })
}

let service = ModelService(store: .standard(), makeModel: mlxModel, gpu: gpuCheck)

let idle = IdleExit(after: IdleExit.interval(appDomain: XiaolaiDictIdentity.app)) {
    log.notice("idle; exiting so the model's memory goes with the process")
    exit(0)
}
idle.start()

/// A received message is not `Sendable`, but its reply may be sent once the answer exists — which is
/// later, and on another thread, for a model. Handed off to a queue XPC was told about
/// (`handoffReply(to:_:)`), rather than simply carried across on our own account.
struct PendingReply: @unchecked Sendable {
    let message: XPCReceivedMessage
}

let requests = DispatchQueue(label: "\(XiaolaiDictIdentity.modelService).requests")

let listener = try XPCListener(
    service: XiaolaiDictIdentity.modelService,
    targetQueue: requests,
    requirement: .isFromSameTeam(andMatchesSigningIdentifier: XiaolaiDictIdentity.app)
) { request in
    // One session's work, tracked on its own: a cancellation means *this* client has gone, and
    // taking other sessions' generations away with it would abandon callers still waiting.
    let session = SessionWork()
    return request.accept(
        incomingMessageHandler: { (message: XPCReceivedMessage) -> (any Encodable)? in
            let decoded: ModelRequest
            do {
                decoded = try message.decode(as: ModelRequest.self)
            } catch {
                return ModelReply.failure(.invalidRequest("\(error)"))
            }
            // Counted in **here**, not inside the task: between XPC accepting this message and that
            // task starting, the idle watch would otherwise be free to decide nothing is happening.
            // Nil once the service is ending — answered here rather than started and then killed.
            guard let lease = idle.admit() else {
                return ModelReply.failure(.generationFailed("the service is shutting down"))
            }
            let pending = PendingReply(message: message)
            return pending.message.handoffReply(to: requests) {
                // Made and tracked under the session's own lock: work handed over afterwards can run
                // in the gap, which is how a generation once outlived the client it was for.
                let started = session.run {
                    defer { lease.release() }
                    let reply: ModelReply
                    if case .unload = decoded {
                        // **Everything in flight is answered first**, and nothing new is admitted
                        // while they finish: exiting over a running generation kills it without a
                        // reply, and its caller waits out a deadline for an answer never coming.
                        lease.release()
                        let quiet = await idle.drain(within: ModelShutdown.drain)
                        if !quiet { log.error("unloading with requests still running") }
                        reply = .unloading
                    } else {
                        do {
                            reply = try await withDeadline(watchdogLimit) { await service.reply(to: decoded) }
                        } catch is CancellationError {
                            // The client went while this ran. There is nobody to answer, and this is
                            // not the watchdog: reporting it as one would end the service for a
                            // reader who simply closed the panel.
                            return
                        } catch {
                            // **The process is the unit of recovery.** MLX's generation is a Metal
                            // call that does not honour cancellation, so nothing here can get the
                            // model back: the answer never arrives, and anything asked after it
                            // queues behind a GPU that may be wedged. The caller is told, and then
                            // this process ends so launchd hands the next question a fresh one.
                            log.fault("no answer within \(watchdogLimit, privacy: .public); ending the service")
                            pending.message.reply(
                                ModelReply.failure(.generationFailed("no answer within \(watchdogLimit)")))
                            await exitOnce(session.isClosed, code: EX_SOFTWARE)
                            return  // `exitOnce` does not come back; the compiler cannot see that
                        }
                    }
                    pending.message.reply(reply)
                    if case .unloading = reply {
                        log.notice("unloading on request")
                        await exitOnce(session.isClosed)
                    }
                }
                if !started {
                    lease.release()
                    pending.message.reply(ModelReply.failure(.generationFailed("the client had gone")))
                }
            }
        },
        cancellationHandler: { _ in
            // The client has gone. After an unload that is the acknowledgement this process waits
            // for; otherwise it means whatever was being generated is generated for nobody.
            session.close()
        })
}

/// Ends the process once the caller has had its answer. The client cancels its session the moment it
/// reads `.unloading`, and **that session's** cancellation is the acknowledgement — a fixed sleep was
/// a guess a slower machine could lose, and a flag shared by every session would read one client's
/// goodbye as another's. Bounded, because a client that never cancels must not keep a 3 GB process
/// alive; `closed` is re-read each turn, so this is the current reply's acknowledgement or nothing.
func exitOnce(_ closed: @autoclosure () -> Bool, code: Int32 = 0) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !closed(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    exit(code)
}


log.notice("model service listening")
withExtendedLifetime(listener) { dispatchMain() }
