import Foundation

/// A guest connecting to this Mac, as Parsec's log tells it.
nonisolated struct ParsecConnect: Equatable, Sendable {
    /// When the `connected.` line was written, to the second.
    var at: Date
    /// From the `net` line just before it, in `ClientAddress` form. Nil if there was none.
    var address: String?
}

/// Reads `~/.parsec/log.txt`. Each line is `[<level> <yyyy-MM-dd> <HH:mm:ss>] <message>`, in local time. A
/// guest's connect is `<account> connected.`, and 0 to 5 seconds before it Parsec writes the guest's
/// address as `net = BUD|<address>|<port>`. A `net` line also comes when this Mac connects out to another
/// host, with no connect line after it, so a `net` line counts only for a connect that follows it closely.
nonisolated enum ParsecLog {
    /// How long before its connect line a `net` line can be. All 19 real connects had it within 5 s.
    static let pairingSeconds = 30.0
    /// The end of the log that's read. The connect wanted is under a minute old, and a minute of a live
    /// session is a few kilobytes.
    static let tailBytes = 256 * 1024

    /// The newest connect in `text`, or nil if there's none or a disconnect follows it.
    static func latestConnect(in text: String, timeZone: TimeZone) -> ParsecConnect? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var latest: ParsecConnect?
        var net: (at: Date, address: String?)?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let (at, message) = parse(line, calendar) else { continue }
            if let address = netAddress(message) {
                net = (at, ClientAddress.normalized(address))
            } else if isGuestLine(message, ending: " connected.") {
                let paired = net.flatMap { at.timeIntervalSince($0.at) <= pairingSeconds ? $0.address : nil }
                latest = ParsecConnect(at: at, address: paired)
                net = nil
            } else if isGuestLine(message, ending: " disconnected.") {
                latest = nil
                net = nil
            }
        }
        return latest
    }

    /// Why `tail(of:)` didn't open a file.
    struct NotARegularFile: Error {}

    /// The end of the file at `url`, from the first whole line in it. Only a regular file is opened,
    /// because this runs on the main actor, and opening or reading a FIFO or a device can block. At most
    /// `tailBytes` are read, even if the file grows meanwhile.
    static func tail(of url: URL) throws -> String {
        // stat follows a symbolic link, so a link to the log is read like the log.
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw NotARegularFile() }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: tailBytes) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    /// The time and the message, or nil for a line that isn't in Parsec's form.
    private static func parse(_ line: Substring, _ calendar: Calendar) -> (Date, Substring)? {
        // "[I 2026-11-06 15:56:37] " is 24 characters.
        let bytes = Array(line.utf8.prefix(24))
        guard bytes.count == 24, bytes[0] == UInt8(ascii: "["), bytes[2] == UInt8(ascii: " "),
            bytes[22] == UInt8(ascii: "]"), bytes[23] == UInt8(ascii: " ")
        else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "-"), bytes[13] == UInt8(ascii: " "),
            bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: ":"),
            let year = number(3..<7), let month = number(8..<10), let day = number(11..<13),
            let hour = number(14..<16), let minute = number(17..<19), let second = number(20..<22),
            // The calendar would roll a month 13 into the next year rather than refuse it.
            (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61,
            let date = calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute, second: second
            ))
        else { return nil }
        let message = line.utf8.dropFirst(24)
        return (date, Substring(message))
    }

    /// `net           = BUD|::ffff:192.168.0.232|31938` gives `::ffff:192.168.0.232`.
    private static func netAddress(_ message: Substring) -> String? {
        guard message.hasPrefix("net ") else { return nil }
        let value = message.drop { $0 != "=" }.dropFirst().drop { $0 == " " }
        let fields = value.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        return String(fields[1])
    }

    /// One word, the account, then the ending: `guest01#1234567 connected.`
    private static func isGuestLine(_ message: Substring, ending: String) -> Bool {
        guard message.hasSuffix(ending) else { return false }
        let account = message.dropLast(ending.count)
        return !account.isEmpty && !account.contains(" ")
    }
}
