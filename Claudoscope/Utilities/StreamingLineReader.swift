import Foundation

/// Reads lines from a FileHandle without loading the entire file into memory.
/// Yields one line at a time, stripping the newline delimiter.
///
/// Implemented as a class to avoid copy-hazard: the mutable buffer and FileHandle
/// seek position must not diverge across independent copies.
final class StreamingLineReader: Sequence, IteratorProtocol {
    private let fileHandle: FileHandle
    private let chunkSize: Int
    private var buffer = Data()
    /// Offset (relative to `buffer.startIndex`) of the first byte of the next
    /// line still to be returned. Advancing this cursor — instead of recopying
    /// the unconsumed tail on every line — is what turns the old O(n²) reader
    /// into O(n): a file with N lines no longer copies ~N² bytes.
    private var lineStart = 0
    private var isEOF = false
    private static let newline = UInt8(ascii: "\n")

    init(fileHandle: FileHandle, chunkSize: Int = 256 * 1024) {
        self.fileHandle = fileHandle
        self.chunkSize = chunkSize
    }

    func next() -> String? {
        while true {
            let base = buffer.startIndex

            // Scan for the next newline from the cursor. Slicing Data yields a
            // cheap view that shares the parent's index space (no copy), so we
            // only ever materialize the one line we return.
            if let nl = buffer[(base + lineStart)...].firstIndex(of: Self.newline) {
                let lineData = buffer[(base + lineStart)..<nl]
                lineStart = (nl - base) + 1
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                return line
            }

            // No complete line buffered. Drop the already-consumed prefix before
            // pulling more bytes so the buffer stays bounded. This compaction runs
            // at most once per chunk read, keeping total copy work O(n).
            if lineStart > 0 {
                buffer.removeSubrange(base..<(base + lineStart))
                lineStart = 0
            }

            if isEOF {
                // Return the trailing partial line (no terminating newline), if any.
                if buffer.startIndex < buffer.endIndex {
                    let remaining = buffer[buffer.startIndex..<buffer.endIndex]
                    buffer.removeAll(keepingCapacity: false)
                    lineStart = 0
                    return String(data: remaining, encoding: .utf8)
                }
                return nil
            }

            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                isEOF = true
            } else {
                buffer.append(chunk)
            }
        }
    }
}
