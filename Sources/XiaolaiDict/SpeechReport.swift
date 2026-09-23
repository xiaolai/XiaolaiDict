import AVFoundation
import Foundation
import XiaolaiDictCore

/// Spike S1: what voices a **signed app bundle** actually has, and whether it can synthesise with
/// them.
///
/// It exists because two measurements of the same machine disagreed and a third showed why:
///
/// ```
/// swift -e        → 52 voices in scope, 3 non-default, Siri identifier resolves
/// compiled binary → 180 voices primed, Siri and premium NOT RESOLVABLE,
///                   a compact voice resolves but synthesises 0 frames
/// ```
///
/// A bare CLI binary is not a valid instrument for this API — exactly as the screen-word spike
/// found for TCC-gated work: the binary inherits the terminal app's grants, and there is no bundle
/// to grant them to. So this runs inside the real bundle, and **counts frames** rather than
/// trusting that `speak` returned without complaining. Synthesising zero frames is the failure
/// mode that looks like success.
enum SpeechReport {
    /// Long enough to be unambiguous, short enough to finish quickly.
    static let utterance = "The ship's hold was full."
    /// A voice that never calls back is a finding, not a reason to hang.
    static let limit: Duration = .seconds(10)

    static func run(write: (String) -> Bool = LookupCommand.writeLine) async -> CommandStatus {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        var byQuality: [String: Int] = [:]
        for voice in voices { byQuality[Self.name(of: voice.quality), default: 0] += 1 }

        // Can each interesting identifier be resolved back to a voice? This is where the compiled
        // binary and the bundle disagreed.
        let interesting = voices.filter { $0.quality != .default || $0.identifier.contains("siri") }
        var resolvable = 0
        var unresolvable: [String] = []
        for voice in interesting {
            if AVSpeechSynthesisVoice(identifier: voice.identifier) != nil {
                resolvable += 1
            } else {
                unresolvable.append(voice.identifier)
            }
        }

        // The measurement that matters: does it produce audio? A voice that resolves and then
        // renders nothing is the trap this spike was written for.
        var synthesis: [[String: Any]] = []
        for voice in Self.probes(among: voices) {
            let frames = await Self.frames(for: voice)
            synthesis.append([
                "identifier": voice.identifier, "name": voice.name,
                "language": voice.language, "quality": Self.name(of: voice.quality),
                "frames": frames ?? -1, "spoke": (frames ?? 0) > 0,
            ])
        }

        let report: [String: Any] = [
            "bundle": Bundle.main.bundleIdentifier ?? "none",
            "insideBundle": Bundle.main.bundleIdentifier != nil,
            "voices": voices.count,
            "byQuality": byQuality,
            "nonDefaultOrSiri": interesting.count,
            "resolvable": resolvable,
            "unresolvable": unresolvable,
            "synthesis": synthesis,
        ]
        guard Instrument.write(report, to: write) else { return .internalError }
        // A report that found no voice that actually speaks is a failed measurement, and says so
        // in its exit status rather than only in its text.
        return synthesis.contains { $0["spoke"] as? Bool == true } ? .success : .failure
    }

    /// One voice per quality for English, plus any Siri voice — enough to answer "can this bundle
    /// speak, and with what" without synthesising 180 times.
    static func probes(among voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        var chosen: [AVSpeechSynthesisVoice] = []
        for quality in [AVSpeechSynthesisVoiceQuality.default, .enhanced, .premium] {
            if let voice = voices.first(where: { $0.language.hasPrefix("en") && $0.quality == quality }) {
                chosen.append(voice)
            }
        }
        if let siri = voices.first(where: { $0.identifier.lowercased().contains("siri") }) { chosen.append(siri) }
        return chosen
    }

    /// The number of audio frames the voice actually rendered, or nil if it never called back.
    /// Counted, not assumed: `speak` returning quietly says nothing about whether audio exists.
    static func frames(for voice: AVSpeechSynthesisVoice) async -> Int? {
        let counter = Counter()
        let utterance = AVSpeechUtterance(string: Self.utterance)
        utterance.voice = voice
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.write(utterance) { buffer in
            guard let audio = buffer as? AVAudioPCMBuffer else { return }
            counter.add(Int(audio.frameLength))
        }
        // Polled rather than continuation-based: `write` hands its callback to another queue, and
        // a voice that never finishes must be a timed-out reading rather than a hung process.
        let deadline = ContinuousClock.now + Self.limit
        while ContinuousClock.now < deadline {
            if let finished = counter.finished { return finished }
            try? await Task.sleep(for: .milliseconds(20))
        }
        withExtendedLifetime(synthesizer) {}
        // Never finished. Whatever it had counted so far is the honest reading, including zero.
        return counter.countedSoFar
    }

    static func name(of quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: "default"
        case .enhanced: "enhanced"
        case .premium: "premium"
        @unknown default: "unknown"
        }
    }

    /// Adds frames until a zero-length buffer says the utterance is finished. `write` signals the
    /// end with an empty buffer; anything that never arrives is caught by the deadline above.
    ///
    /// **Zero frames is the answer this spike exists to catch**, so a finished-with-nothing reading
    /// is kept and reported rather than being treated as a failure to measure.
    final class Counter: @unchecked Sendable {
        private var frames = 0
        private var isDone = false
        private let lock = NSLock()

        func add(_ count: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard !isDone else { return }
            if count == 0 { isDone = true } else { frames += count }
        }

        var finished: Int? {
            lock.lock()
            defer { lock.unlock() }
            return isDone ? frames : nil
        }

        var countedSoFar: Int {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }
    }
}
