/// Decoding of the NUL-terminated buffers the BSD APIs hand back.
///
/// `String(cString:)` is deprecated and its replacements differ per input
/// shape, so the conversion lives in one place instead of being re-derived at
/// every syscall boundary.
enum CString {
    /// Decodes a fixed-size buffer, stopping at the first NUL.
    static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Decodes the first `length` bytes, for calls that report how much they
    /// wrote.
    static func string(_ buffer: [CChar], length: Int) -> String {
        string(Array(buffer.prefix(length)))
    }

    static func string(_ pointer: UnsafePointer<CChar>) -> String {
        String(validatingCString: pointer) ?? ""
    }
}
