import Foundation

/// One SubRip cue: a time window and the text shown during it.
struct SRTCue: Equatable {
    /// Inclusive start, in milliseconds from the media start.
    let startMs: Int
    /// Inclusive end, in milliseconds.
    let endMs: Int
    /// Display text. Multi-line cues keep their newlines.
    let text: String

    /// Whether `timeMs` falls inside this cue's window.
    func contains(_ timeMs: Int) -> Bool {
        timeMs >= startMs && timeMs <= endMs
    }
}

/// Minimal SubRip (.srt) parser + cue lookup. Pure value logic — no I/O — so it
/// is trivial to unit-test and reuse. Phase A of stable subtitles: a sidecar
/// `.srt` beside the video is parsed here and rendered as a SwiftUI overlay,
/// which stays screen-stable in VLC Cover mode (native VLC subtitles do not).
enum SRTSubtitleParser {
    /// Parse a full `.srt` document into ordered cues. Tolerant of the common
    /// real-world quirks: CRLF or LF line endings, a UTF-8 BOM, blank lines
    /// between blocks, missing index numbers, and `.` or `,` as the millisecond
    /// separator. Cues are returned sorted by start time so lookup can rely on
    /// order. Malformed blocks are skipped rather than failing the whole file.
    static func parse(_ raw: String) -> [SRTCue] {
        // Normalize line endings and strip a leading BOM if present.
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.first == "\u{FEFF}" { text.removeFirst() }

        var cues: [SRTCue] = []

        // Blocks are separated by one or more blank lines.
        for block in text.components(separatedBy: "\n\n") {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            // Drop leading/trailing empties left by extra blank lines.
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            guard !lines.isEmpty else { continue }

            // An optional numeric index line precedes the timing line. If the
            // first line isn't a timing line, treat it as the index and drop it.
            var idx = 0
            if !lines[idx].contains("-->") {
                idx += 1
            }
            guard idx < lines.count, lines[idx].contains("-->") else { continue }

            guard let (start, end) = parseTimingLine(lines[idx]) else { continue }
            let textLines = lines[(idx + 1)...]
            let cueText = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cueText.isEmpty else { continue }

            cues.append(SRTCue(startMs: start, endMs: end, text: cueText))
        }

        return cues.sorted { $0.startMs < $1.startMs }
    }

    /// Parse a `HH:MM:SS,mmm --> HH:MM:SS,mmm` line into start/end milliseconds.
    /// Any trailing position coordinates after the end stamp are ignored.
    private static func parseTimingLine(_ line: String) -> (Int, Int)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2,
              let start = parseTimestamp(parts[0]),
              let end = parseTimestamp(parts[1]) else { return nil }
        return (start, end)
    }

    /// Parse one `HH:MM:SS,mmm` (or `.mmm`) stamp into milliseconds. Tolerates
    /// surrounding whitespace and a trailing position string on the end stamp.
    private static func parseTimestamp(_ raw: String) -> Int? {
        // Keep only the leading time token (ignore trailing "X1:.. Y1:.." coords).
        let token = raw.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        let normalized = token.replacingOccurrences(of: ".", with: ",")
        let hms = normalized.components(separatedBy: ",")
        guard hms.count == 2 else { return nil }

        let clock = hms[0].components(separatedBy: ":")
        guard clock.count == 3,
              let h = Int(clock[0]),
              let m = Int(clock[1]),
              let s = Int(clock[2]),
              let ms = Int(hms[1]) else { return nil }

        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }

    /// The cue active at `timeMs`, or nil if none. Linear scan — cue lists are
    /// small (a feature is a few thousand cues) and this runs only when the cue
    /// window changes, so a binary search isn't worth the complexity here.
    static func cue(at timeMs: Int, in cues: [SRTCue]) -> SRTCue? {
        cues.first { $0.contains(timeMs) }
    }
}
