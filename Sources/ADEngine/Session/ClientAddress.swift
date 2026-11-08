import Darwin
import Foundation

/// A device's network address in one plain form, so the address Parsec logs and the one the user types
/// compare equal however each is written.
nonisolated enum ClientAddress {
    /// IPv4 as dotted digits, IPv4 written as IPv6 (`::ffff:192.168.0.232`, which is how Parsec logs it)
    /// as plain IPv4, and other IPv6 in its short lowercase form. Nil if the text isn't an address.
    static func normalized(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return withUnsafeBytes(of: v4) { format(AF_INET, $0, length: INET_ADDRSTRLEN) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return bytes[12...].map(String.init).joined(separator: ".")
        }
        return withUnsafeBytes(of: v6) { format(AF_INET6, $0, length: INET6_ADDRSTRLEN) }
    }

    private static func format(_ family: Int32, _ address: UnsafeRawBufferPointer, length: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(length))
        guard inet_ntop(family, address.baseAddress, &buffer, socklen_t(length)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
