import Darwin
import Foundation

/// Which sizes of the local model this Mac can run — decided **before** anything is loaded.
///
/// Before, because nothing afterwards will stop a model that does not fit. Measured in the MLX-in-XPC
/// spike (S3): capped at 1,500 MB, MLX still loaded a 2,159 MB model, 44% over its own limit; and with
/// free memory driven to 60 MB and 6.6 GB swapped, the kernel's pressure level stayed *normal* and
/// the pressure handler fired zero times. Neither defence exists, so the size is chosen here, from
/// numbers, and never by trying.
///
/// A pure function of two numbers, so every Mac it will meet can be tested without owning one.
public enum ModelSizing {
    /// A size is **offered** where its peak is at most a quarter of the Mac's memory. The reader's
    /// own apps are the other three quarters, and a dictionary is the smallest thing they are
    /// running. Against the measured process peaks that is a floor of **14.0 GB** — 4B peaks at
    /// 3,585 MB, so a quarter of 16 GB (4,096) holds it and a quarter of 12 (3,072) does not — and
    /// **25.9 GB** for 9B, so 32 GB and up offers both. Of the memory sizes Apple Silicon actually
    /// ships, only **8 GB is offered nothing**: it reads with the engines it has, which is the
    /// decision recorded on `LocalModelSize` rather than a gap to close by loosening this share.
    public static let shareOfPhysicalMemory: UInt64 = 4

    /// What must be left free **after** loading, so the answer does not push the Mac into swap.
    public static let headroom: UInt64 = 1_024 * LocalModelSize.megabyte

    /// The sizes this Mac could ever run, smallest first. Empty where not even the floor fits —
    /// which is "this Mac has too little memory", a state and not an error.
    public static func offered(physicalMemory: UInt64) -> [LocalModelSize] {
        LocalModelSize.allCases.filter { $0.peakMemory <= physicalMemory / shareOfPhysicalMemory }
    }

    /// The sizes that may be loaded **now**: offered by the Mac, and fitting in what is free with
    /// room to spare.
    public static func eligible(physicalMemory: UInt64, availableMemory: UInt64) -> [LocalModelSize] {
        offered(physicalMemory: physicalMemory).filter { $0.peakMemory + headroom <= availableMemory }
    }

    /// What a reader is offered first: 4B where the Mac offers it, and otherwise nothing. **Never
    /// 9B** — it is an opt-in, twice the time and memory for a little more idiom, and a default the
    /// reader did not choose should not cost that.
    ///
    /// Written as a filter and a `max` rather than as "4B if offered", because that is the shape
    /// that stays correct if a size is ever added between the two: the clause says *the largest the
    /// Mac can hold that is no bigger than 4B*, which happens to have one answer today.
    public static func recommended(physicalMemory: UInt64) -> LocalModelSize? {
        offered(physicalMemory: physicalMemory).filter { $0 <= .standard }.max()
    }

    /// Whether the installed size may be loaded now. The service asks this before every load.
    public static func mayLoad(_ size: LocalModelSize, physicalMemory: UInt64, availableMemory: UInt64) -> Bool {
        eligible(physicalMemory: physicalMemory, availableMemory: availableMemory).contains(size)
    }
}

/// This Mac's memory, as sizing needs it.
///
/// **Available is not free, and it is not free plus inactive either.** macOS keeps free pages near
/// zero on purpose, so `free_count` alone would call every busy Mac full — but counting all of
/// `inactive_count` is the other error: an inactive page holding anonymous memory is reclaimed by
/// compressing or swapping it, which is exactly the cost this gate exists to avoid. What is counted
/// is what can be had without that: free pages, purgeable ones, and file-backed pages, which are
/// clean copies of something already on disk. Speculative pages are not added, because XNU already
/// counts them in `free_count`, and adding them again admitted a model twice over.
public enum SystemMemory {
    public static var physical: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Nil when the kernel would not say — which the caller must treat as "not known", never as
    /// "plenty".
    public static func available() -> UInt64? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        // The host port is a send right, and one is taken on every call. Given back here: IOKit's
        // own code does the same, for the same reason.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return reclaimable(info) * UInt64(getpagesize())
    }

    /// The pages a load can have without compressing or swapping anything. Split out so the
    /// accounting itself can be tested against numbers a Mac would report.
    ///
    /// **Speculative pages are subtracted once.** They are file-backed read-ahead, so they are
    /// inside `external_page_count`; whether `free_count` counts them as well was not settled
    /// here — two readings of a live Mac differ by more than the speculative count, so the
    /// experiment cannot answer it. Subtracting is the conservative reading: if the kernel does
    /// count them twice, this stops a load going ahead without the headroom it was promised, and
    /// if it does not, the cost is the speculative count itself — measured at 7 to 62 MB on this
    /// Mac, against a gigabyte of headroom.
    ///
    /// Anonymous inactive pages are not here at all: reclaiming those is exactly the compressing
    /// and swapping this gate exists to avoid.
    static func reclaimable(_ info: vm_statistics64_data_t) -> UInt64 {
        let free = UInt64(info.free_count)
        let speculative = UInt64(info.speculative_count)
        return free - min(free, speculative) + UInt64(info.purgeable_count)
            + UInt64(info.external_page_count)
    }

    /// This process's footprint, as Activity Monitor reports it — **nil where the kernel would not
    /// say**, because a zero here is indistinguishable from a process holding nothing. MLX's own
    /// counters leave out what the OS has mapped, so this is the number that decides whether the
    /// Mac swaps.
    public static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
