import Darwin
@testable import ModelKit
import Testing
@testable import XiaolaiDictCore

/// Which size a Mac may run, decided from two numbers before anything is loaded — because nothing
/// afterwards will stop a model that does not fit: MLX loaded 2,159 MB under a 1,500 MB limit, and
/// the pressure handler fired zero times with 6.6 GB swapped (the MLX-in-XPC spike, S3).
struct ModelSizingTests {
    private static let gigabyte: UInt64 = 1_073_741_824

    /// Every Mac the plan names, and what each is offered. A quarter of memory is the budget, and
    /// the peaks it is spent against are the measured process footprints at load — which is why 8 GB
    /// is offered nothing and 9B waits for 32 GB.
    @Test(arguments: [
        (8, [LocalModelSize]()),
        (16, [.small, .standard]),
        (24, [.small, .standard]),
        (32, [.small, .standard, .large]),
        (48, [.small, .standard, .large]),
    ])
    func eachMacIsOfferedTheSizesItCanHold(gigabytes: Int, offered: [LocalModelSize]) {
        #expect(ModelSizing.offered(physicalMemory: UInt64(gigabytes) * Self.gigabyte) == offered)
    }

    /// 4B where the Mac holds it, 2B below that — and **never 9B unasked**, however much memory
    /// there is: it is twice the time for a little more idiom.
    @Test(arguments: [
        (16, LocalModelSize?.some(.standard)),
        (24, .standard),
        (32, .standard),
        (48, .standard),
        // Below the floor there is nothing to offer, and that is a state the board shows — not a
        // size to be tried anyway.
        (8, nil),
        (4, nil),
    ])
    func theDefaultIsFourBWhereItFitsAndNeverNineB(gigabytes: Int, recommended: LocalModelSize?) {
        #expect(ModelSizing.recommended(physicalMemory: UInt64(gigabytes) * Self.gigabyte) == recommended)
    }

    @Test func aMacBelowTheFloorIsOfferedNothing() {
        #expect(ModelSizing.offered(physicalMemory: 4 * Self.gigabyte).isEmpty)
        #expect(ModelSizing.offered(physicalMemory: 8 * Self.gigabyte).isEmpty, "2B peaks above a quarter of 8 GB")
    }

    /// Memory the Mac has is not memory that is free. A 48 GB Mac with 3 GB available can load
    /// nothing — 2B peaks at 2,098 MB and wants 1 GB left over; with 2B's peak plus that headroom
    /// free it may load 2B, and with 4B's, 4B too.
    @Test func lowFreeMemoryNarrowsWhatMayLoadNow() {
        let physical = 48 * Self.gigabyte
        #expect(ModelSizing.eligible(physicalMemory: physical, availableMemory: 3 * Self.gigabyte).isEmpty)
        #expect(ModelSizing.eligible(
            physicalMemory: physical,
            availableMemory: LocalModelSize.small.peakMemory + ModelSizing.headroom) == [.small])
        let justEnough = LocalModelSize.standard.peakMemory + ModelSizing.headroom
        #expect(ModelSizing.eligible(physicalMemory: physical, availableMemory: justEnough) == [.small, .standard])
        #expect(ModelSizing.eligible(physicalMemory: physical, availableMemory: justEnough - 1) == [.small])
        #expect(ModelSizing.eligible(physicalMemory: physical, availableMemory: 512 * 1_048_576).isEmpty)
    }

    /// **Available is what can be had without compressing or swapping**: free pages, purgeable ones,
    /// and file-backed pages — never the anonymous inactive ones, which cost exactly what this gate
    /// exists to avoid, and never speculative pages twice, which XNU already counts as free.
    @Test func availableMemoryCountsOnlyWhatCanBeReclaimedForFree() {
        var info = vm_statistics64_data_t()
        info.free_count = 1_000          // includes the speculative pages below
        info.speculative_count = 200
        info.purgeable_count = 50
        info.external_page_count = 300   // clean copies of files — the speculative ones among them
        info.inactive_count = 5_000      // anonymous: compressed or swapped to reclaim
        info.active_count = 9_000
        // 1,000 free less the 200 speculative, plus 50 purgeable and 300 file-backed. The
        // speculative pages are counted **once**, inside the file-backed total.
        #expect(SystemMemory.reclaimable(info) == 1_150)

        // Never below zero, whatever a kernel reports: a speculative count larger than the free one
        // would otherwise wrap around to an enormous "available".
        var odd = vm_statistics64_data_t()
        odd.free_count = 10
        odd.speculative_count = 400
        odd.external_page_count = 100
        #expect(SystemMemory.reclaimable(odd) == 100)
    }

    /// A Mac reports what it reports: the live reading is a number of bytes, or nothing.
    @Test func thisMacAnswersWithBytesOrNothing() {
        #expect(SystemMemory.physical > 0)
        if let available = SystemMemory.available() {
            #expect(available > 0 && available < SystemMemory.physical)
        }
        #expect(SystemMemory.footprint() ?? 1 > 0, "a footprint of zero is a failed measurement, not a fact")
    }

    /// The peaks are the measured process footprints at load, not MLX's own counters, which leave
    /// out what the OS has mapped and undercount every size.
    @Test func thePeaksAreTheMeasuredProcessFootprints() {
        #expect(LocalModelSize.small.peakMemory == 2_098 * 1_048_576)
        #expect(LocalModelSize.standard.peakMemory == 3_585 * 1_048_576)
        #expect(LocalModelSize.large.peakMemory == 6_633 * 1_048_576)
    }

    /// Free memory never promotes a size the Mac itself is not offered: 16 GB with 12 GB free is
    /// still not a 9B Mac.
    @Test func freeMemoryNeverPromotesPastWhatTheMacIsOffered() {
        #expect(ModelSizing.eligible(physicalMemory: 16 * Self.gigabyte, availableMemory: 12 * Self.gigabyte)
            == [.small, .standard])
        #expect(!ModelSizing.mayLoad(.large, physicalMemory: 16 * Self.gigabyte, availableMemory: 12 * Self.gigabyte))
    }

    /// The loader's question, at the edge: exactly the peak plus headroom loads, a byte less does not.
    @Test func theLoadGateIsExactAtItsEdge() {
        let physical = 32 * Self.gigabyte
        let edge = LocalModelSize.large.peakMemory + ModelSizing.headroom
        #expect(ModelSizing.mayLoad(.large, physicalMemory: physical, availableMemory: edge))
        #expect(!ModelSizing.mayLoad(.large, physicalMemory: physical, availableMemory: edge - 1))
    }
}
