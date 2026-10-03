import Testing
@testable import XiaolaiDictCore

struct LookupTimelineTests {
    private static let origin = ContinuousClock.now

    /// One line per lookup, each stage measured from when the reader asked. Red if a stage is
    /// measured from the previous one, or the source is lost.
    @Test func aLookupIsOneLineMeasuredFromTheAsk() {
        var timeline = LookupTimeline()
        timeline.begin(request: 12, at: Self.origin, source: "accessibilityTextRange")
        timeline.mark(.captured, request: 12, at: Self.origin + .milliseconds(8))
        timeline.mark(.panelShown, request: 12, at: Self.origin + .milliseconds(20))
        timeline.mark(.dictionaryAnswered, request: 12, at: Self.origin + .milliseconds(140))
        timeline.mark(.senseResolved, request: 12, at: Self.origin + .milliseconds(900))
        #expect(timeline.finish(request: 12, at: Self.origin + .milliseconds(950))
                == "request 12 · accessibilityTextRange · captured 8 ms · panel 20 ms · dictionary 140 ms · sense 900 ms · recorded 950 ms")
    }

    /// The first arrival counts; a stage reached again is not a second measurement.
    @Test func aStageIsMarkedOnce() {
        var timeline = LookupTimeline()
        timeline.begin(request: 1, at: Self.origin, source: "s")
        timeline.mark(.panelShown, request: 1, at: Self.origin + .milliseconds(5))
        timeline.mark(.panelShown, request: 1, at: Self.origin + .milliseconds(50))
        #expect(timeline.finish(request: 1, at: Self.origin + .milliseconds(60)) == "request 1 · s · panel 5 ms · recorded 60 ms")
    }

    /// A request never begun has no line, and a finished one cannot be finished twice.
    @Test func onlyABegunLookupFinishes() {
        var timeline = LookupTimeline()
        #expect(timeline.finish(request: 3, at: Self.origin) == nil)
        timeline.begin(request: 3, at: Self.origin, source: "s")
        #expect(timeline.finish(request: 3, at: Self.origin) != nil)
        #expect(timeline.finish(request: 3, at: Self.origin) == nil)
    }

    /// **Bounded.** A superseded lookup is never recorded; past the capacity the oldest is
    /// forgotten rather than kept for the life of the process.
    @Test func theOldestUnfinishedLookupIsForgotten() {
        var timeline = LookupTimeline()
        for request in 0...LookupTimeline.capacity { timeline.begin(request: request, at: Self.origin, source: "s") }
        #expect(timeline.finish(request: 0, at: Self.origin) == nil)
        #expect(timeline.finish(request: LookupTimeline.capacity, at: Self.origin) != nil)
    }
}

extension LookupTimelineTests {
    /// A write that failed is said, not called "recorded". Red if `finish` ignores the outcome.
    @Test func aFailedWriteIsNotCalledRecorded() {
        var timeline = LookupTimeline()
        timeline.begin(request: 9, at: Self.origin, source: "s")
        let line = timeline.finish(request: 9, at: Self.origin + .milliseconds(5), ending: .notRecorded)
        #expect(line == "request 9 · s · not recorded 5 ms")
    }

    /// **A lookup that ended with nothing to record still says so** (audit round 3, #39). Superseded,
    /// dismissed or never drawn, it used to leave no line at all — the timings it existed to measure
    /// went missing exactly where a reader was kept waiting.
    @Test func aDroppedLookupIsSaidAsDropped() {
        var timeline = LookupTimeline()
        timeline.begin(request: 4, at: Self.origin, source: "s")
        let line = timeline.finish(request: 4, at: Self.origin + .milliseconds(7), ending: .notShown)
        #expect(line == "request 4 · s · not shown 7 ms")
        // **Shown and then replaced is a different ending** (round 3 re-verify): the reader saw this one.
        timeline.begin(request: 5, at: Self.origin, source: "s")
        #expect(timeline.finish(request: 5, at: Self.origin + .milliseconds(9), ending: .superseded)
            == "request 5 · s · superseded 9 ms")
    }
}
