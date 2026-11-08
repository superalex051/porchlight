import Foundation

/// Parsec's log lines, in the shapes the real `~/.parsec/log.txt` has them (2026-11-06 and 2026-11-07),
/// with times in UTC so a test can put them at its clock's `now`.
enum ParsecFixture {
    static let utc = TimeZone(identifier: "UTC")!
    static let account = "guest01#1234567"
    static let macBook = "192.168.0.232"

    /// `yyyy-MM-dd HH:mm:ss`, as Parsec writes it.
    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func line(_ level: String, _ date: Date, _ message: String) -> String {
        "[\(level) \(stamp(date))] \(message)"
    }

    /// A guest connecting to this Mac from `address`, the connect line at `date` and the `net` line `netLead`
    /// seconds before it, with the lines Parsec writes between them. Nil `address` leaves the `net` line out.
    static func connect(from address: String? = "::ffff:\(macBook)", at date: Date, netLead: Double = 4) -> [String] {
        let net = date.addingTimeInterval(-netLead)
        var lines = [line("I", net, "STUN reply from ::ffff:35.169.37.243:3478")]
        if let address {
            lines.append(line("D", net, "net           = BUD|\(address)|31938"))
        }
        lines += [
            line("D", net, "BUD AES_GCM   = 256"),
            line("D", net, "vp_supported  = 1"),
            line("I", net, "Parsec Virtual USB Adapter failed to initialize, no virtual device support"),
            line("I", net, "Failed to initialize host gamepad input via ViGEm"),
            line("D", date, "capture       = macos_capture"),
            line("I", date, "\(account) connected."),
            line("D", date, "architecture  = Apple Silicon"),
            line("D", date, "encoder       = Hardware"),
            line("D", date, "codec         = h265"),
            line("D", date, "encode_x      = 2560"),
            line("D", date, "encode_y      = 1440"),
            line("D", date.addingTimeInterval(2), "[0] FPS:46.5/505, L:8.2/37.1, B:3.6/10.0, N:0/0/0"),
        ]
        return lines
    }

    static func disconnect(at date: Date) -> [String] {
        [
            line("D", date, "vp_supported  = 0"),
            line("I", date, "\(account) disconnected."),
            line("D", date, "vte_dropped   = 22"),
        ]
    }

    /// This Mac connecting out to another Parsec host: a `net` line with no connect line after it.
    static func outgoing(to address: String = "::ffff:192.168.0.154", at date: Date) -> [String] {
        [
            line("I", date, "Client Status received: 20"),
            line("I", date, "STUN reply from ::ffff:52.86.26.213:3478"),
            line("D", date, "net           = BUD|\(address)|22967"),
            line("D", date, "BUD AES_GCM   = 256"),
            line("I", date, "Client Status received: 0"),
            line("D", date, "decoder       = vt"),
        ]
    }

    /// Lines that mention connecting but aren't a guest's connect.
    static func noise(at date: Date) -> [String] {
        [
            line("D", date, "MTY_WebSocketRead_block_invoke_2: NSURLSessionWebSocketTask:receiveMessage failed: "
                + "The operation couldn\u{2019}t be completed. Socket is not connected"),
            line("D", date, "BG: /me requested. Current interval: 2197 seconds"),
            "",
        ]
    }

    static func write(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    /// Parsec's config in the shape of the real `~/.parsec/config.json` (2026-11-08): an array holding a
    /// comment and one object, each key's value wrapped as `{"value": ...}`, indented with tabs. Every
    /// value but the two resolution keys is made up. A nil `size` leaves those two keys out.
    static func config(_ size: (w: Int, h: Int)?) -> String {
        var entries: [(String, String)] = [
            ("app_changelog_ver", "1"),
            ("app_channel", "\"release10\""),
            ("app_flags", "0"),
            ("app_host", "true"),
            ("client_overlay_button_x", "0"),
            ("client_overlay_button_y", "0"),
            ("encoder_bitrate", "50"),
            ("encoder_bitrate_1", "50"),
            ("encoder_bitrate_2", "50"),
            ("host_audio_id", "\"fixture-audio\""),
            ("host_name", "\"Fixture Mac\""),
            ("host_virtual_microphone", "0"),
        ]
        if let size {
            entries += [("server_resolution_x", "\(size.w)"), ("server_resolution_y", "\(size.h)")]
        }
        let body = entries.map { "\t\t\"\($0.0)\": {\n\t\t\t\"value\": \($0.1)\n\t\t}" }.joined(separator: ",\n")
        return "[\n\t\"See https://parsec.app/config for documentation and example. JSON must be valid before saving or "
            + "file be will be erased.\",\n\t{\n\(body)\n\t}\n]"
    }

    /// The config with that size, as if Parsec had saved it at `saved`.
    static func writeConfig(_ size: (w: Int, h: Int)?, savedAt saved: Date, to url: URL) throws {
        try Data(config(size).utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: saved], ofItemAtPath: url.path(percentEncoded: false))
    }
}
