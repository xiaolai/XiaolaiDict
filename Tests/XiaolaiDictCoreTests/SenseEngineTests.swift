import Testing

@testable import XiaolaiDictCore

/// The one place that asks whether Apple's on-device model can run.
struct SenseEngineTests {
    /// It answers, on whichever machine this runs. The development Mac reports
    /// `deviceNotEligible`; the end-to-end Mac reports available. Both are valid here — what is
    /// asserted is that a reason survives when it is unavailable, which is the whole point of the
    /// type. The selector used to drop it.
    @Test func anUnavailableModelAlwaysCarriesAReason() {
        let status = SenseEngine.status()
        switch status {
        case .onDevice:
            #expect(status.isOnDevice)
            #expect(status.reason == nil)
        case .unavailable(let reason):
            #expect(!status.isOnDevice)
            #expect(status.reason == reason)
            #expect(SenseEngineUnavailability.allCases.contains(reason))
        }
    }

    /// Asked twice, it says the same thing. A row that flickered between rungs would be reporting
    /// the reader's machine changing its mind, which it is not.
    @Test func itIsStableWithinARun() {
        #expect(SenseEngine.status() == SenseEngine.status())
    }

    /// Every reason is its own value. A duplicated raw value would make two distinct reasons
    /// decode as one, and the reader would be told the wrong thing about their Mac.
    ///
    /// The round-trip this replaces asserted only that the compiler synthesises `RawRepresentable`
    /// correctly — it could not fail for any mistake in this file.
    @Test func noTwoReasonsShareARawValue() {
        let raw = SenseEngineUnavailability.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count, "two reasons share a raw value: \(raw)")
    }

    /// Every reason Apple can give has a case here, plus the two this build owns. Mapped rather
    /// than passed through because Apple's enum is neither `Codable` nor `CaseIterable` and can
    /// gain a case in a point release.
    @Test func theReasonsCoverApplesAndThisBuildsOwn() {
        let named = Set(SenseEngineUnavailability.allCases.map(\.rawValue))
        #expect(named.isSuperset(of: [
            "deviceNotEligible", "appleIntelligenceNotEnabled", "modelNotReady",
        ]))
        #expect(named.contains("notInThisBuild"))
        #expect(named.contains("unknown"))
    }
}
