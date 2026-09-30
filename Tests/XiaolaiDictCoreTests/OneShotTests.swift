import Testing
import XiaolaiDictBase

/// **A continuation resumed twice ends the process**, so the rule cannot be "the caller is careful".
///
/// `XPCServiceTransport.send` has two paths to one continuation — the reply handler and the `catch`
/// around `session.send` — and nothing documents whether the handler has already run when `send` throws.
/// Every check here crashed the test process before `OneShot` existed, which is the only kind of evidence
/// that matters for this class of defect — ADR-0042.
struct OneShotTests {
    @Test func thefirstAnswerWinsAndTheSecondIsDropped() async {
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let once = OneShot<Int, Never>(continuation)
            once.resume(with: .success(1))
            once.resume(with: .success(2))
            once.resume(with: .success(3))
        }
        #expect(answer == 1)
    }

    @Test func afailureCanBeTheFirstAnswerAndASuccessAfterItIsDropped() async {
        struct Refused: Error, Equatable {}
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Int, any Error>, Never>) in
            let once = OneShot<Result<Int, any Error>, Never>(continuation)
            once.resume(with: .success(.failure(Refused())))
            once.resume(with: .success(.success(7)))
        }
        #expect(throws: Refused.self) { try answer.get() }
    }

    /// The positive control for `hasResumed`: false before the answer, true after it. Without it a
    /// `OneShot` that dropped *every* resume would satisfy the checks above by hanging, which is the
    /// other half of the same defect.
    @Test func itsaysWhetherTheCallerHasBeenAnswered() async {
        var before: Bool?
        var after: Bool?
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let once = OneShot<Int, Never>(continuation)
            before = once.hasResumed
            once.resume(with: .success(4))
            after = once.hasResumed
        }
        #expect(answer == 4)
        #expect(before == false)
        #expect(after == true)
    }
}
