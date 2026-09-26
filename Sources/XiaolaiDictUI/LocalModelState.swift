import ModelKit
import XiaolaiDictCore

/// Where the local model stands on this Mac, as the setup board and the translation pane read it.
///
/// Read from the store and the running download every time it is asked, never remembered: a board
/// that stored "downloaded" would go on saying so after the reader deleted the folder.
public enum LocalModelState: Equatable, Sendable {
    /// Nothing is downloaded, and the Mac can take a model.
    case notDownloaded
    /// `replacing` is the size already installed and still answering — an upgrade to 9B is not the
    /// state of having no model, and a row that said so would call a working model "needed".
    case downloading(ModelDownloadProgress, size: LocalModelSize, replacing: LocalModelSize? = nil)
    /// A size is on disk, whole.
    case ready(LocalModelSize)
    /// The last download stopped. What arrived is kept, and the next attempt resumes from it —
    /// **the size it was**, because what is on disk is a front of that model and no other. Resuming
    /// the recommended size instead would start a second download and strand the first.
    case stopped(reason: String, size: LocalModelSize, replacing: LocalModelSize? = nil)
    /// Not even the smallest size fits this Mac's memory. Nothing for the reader to do about it.
    case tooLittleMemory

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// The size that is answering right now, whatever else is going on: the one installed, or the
    /// one a download is replacing.
    public var answering: LocalModelSize? {
        switch self {
        case .ready(let size): size
        case .downloading(_, _, let replacing), .stopped(_, _, let replacing): replacing
        case .notDownloaded, .tooLittleMemory: nil
        }
    }
}

/// The setup board's model row, and the translation pane's download offer, as `XiaolaiDictUI`
/// needs them. Handed in by the app, which owns the store and the download — the same shape as
/// `DictionaryChoice` and `ShortcutChoice`.
@MainActor
public struct LocalModelChoice {
    public var state: LocalModelState
    /// The reader chose **Not now**. A 3 GB download never starts unasked, and this is what the
    /// board counts as settled short of a download.
    public var declined: Bool
    /// The sizes this Mac is offered, smallest first; empty where memory rules the model out.
    public var offered: [LocalModelSize]
    /// What the row's main button downloads: 4B where the Mac takes it, and nothing below that —
    /// a Mac too small for 4B reads with Apple's on-device model instead.
    public var recommended: LocalModelSize?
    public var download: @MainActor (LocalModelSize) -> Void
    public var decline: @MainActor () -> Void
    public var cancel: @MainActor () -> Void

    public init(
        state: LocalModelState, declined: Bool, offered: [LocalModelSize], recommended: LocalModelSize?,
        download: @escaping @MainActor (LocalModelSize) -> Void, decline: @escaping @MainActor () -> Void,
        cancel: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.declined = declined
        self.offered = offered
        self.recommended = recommended
        self.download = download
        self.decline = decline
        self.cancel = cancel
    }

    /// The next size up this Mac is offered, where a model is on disk and there is a larger one to
    /// move to. A larger model is an opt-in — a little more idiom for twice the time and memory.
    ///
    /// **The next one, not the largest** — `min` over what is bigger, never `offered.max()`.
    /// Written in terms of 9B alone, a reader with 2B on a 16 GB Mac was offered nothing: 9B does
    /// not fit there, so the row said their model was the biggest they could have while 4B — the
    /// recommended size, which does fit — sat unoffered.
    ///
    /// **With 2B gone there are two sizes, so `min` and `max` cannot be told apart by any test**,
    /// and the shape is kept because it is the correct one rather than because something proves it.
    /// A third size makes the distinction observable again. The test that held it was
    /// `theUpgradeOfferedIsTheNextSizeThisMacCanHold` in `LocalModelControllerTests`, which on
    /// 2026-09-26 was repurposed as `aModelAlreadyOnDiskIsFoundAndItsUpgradeOffered` — the shape to
    /// restore beside it, not to restore it to.
    public var larger: LocalModelSize? {
        guard case .ready(let size) = state else { return nil }
        return offered.filter { $0 > size }.min()
    }

    /// What the row's main button would download: the size a stopped download was of — resuming is
    /// not starting something else — or the size this Mac is recommended, where that is one it is
    /// actually offered.
    public var downloadable: LocalModelSize? {
        switch state {
        case .stopped(_, let size, _): return offered.contains(size) ? size : nil
        case .notDownloaded: return recommended.flatMap { offered.contains($0) ? $0 : nil }
        case .downloading, .ready, .tooLittleMemory: return nil
        }
    }

    /// Whether a download can be offered from here: the Mac takes a model, none is on disk, and none
    /// is already on its way. **Not now does not take it away** — the row keeps it one click away.
    public var canDownload: Bool { downloadable != nil }
}
