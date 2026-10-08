import Foundation

/// **A byte stream cut into lines at LF, and at nothing else** — the framing both CLIs' JSON lines use.
///
/// Not `FileHandle.AsyncBytes.lines`: that also ends a line at CR, NEL, U+2028 and U+2029, and JSON does not escape
/// U+2028 or U+2029 inside a string. A model's answer holding one would be cut in two, and each half read as a line
/// that is not JSON. A trailing CR is dropped, so a CRLF line reads as its LF one.
///
/// **Bounded**: a line that grows past `limit` without ending is refused, so a CLI that writes without stopping
/// cannot grow this process's memory without bound.
struct LineFraming: Sendable {
    /// A line grew past the bound.
    struct Overflow: Error, Equatable {}

    let limit: Int
    private var pending = Data()

    init(limit: Int) {
        self.limit = limit
    }

    /// The lines `chunk` completes, each without its LF, in order. What follows the last LF is kept for the next chunk.
    mutating func append(_ chunk: Data) throws(Overflow) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        var start = pending.startIndex
        while let end = pending[start...].firstIndex(of: Self.lineFeed) {
            var line = pending[start..<end]
            if line.last == Self.carriageReturn { line = line.dropLast() }
            guard line.count <= limit else { throw Overflow() }
            lines.append(Data(line))
            start = pending.index(after: end)
        }
        pending = Data(pending[start...])
        guard pending.count <= limit else { throw Overflow() }
        return lines
    }

    /// What was left without an LF when the stream ended — the last line of a writer that did not end it — or nil.
    mutating func finish() -> Data? {
        defer { pending = Data() }
        var line = pending
        if line.last == Self.carriageReturn { line = line.dropLast() }
        return line.isEmpty ? nil : Data(line)
    }

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
}
