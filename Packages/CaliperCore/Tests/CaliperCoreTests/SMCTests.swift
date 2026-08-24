import Testing

@testable import CaliperCore

@Test func decodesTheEncodingsAppleSiliconUses() {
    // `flt` is a little-endian IEEE float: 2317 RPM as the SMC reports it.
    #expect(SMCConnection.decode(type: "flt ", bytes: [0x00, 0xd0, 0x10, 0x45]) == 2317)
    #expect(SMCConnection.decode(type: "ui8 ", bytes: [2]) == 2)
}

@Test func decodesTheFixedPointEncodingsIntelMacsUse() {
    // sp78: signed integer part, then eighths-of-a-256th — 42.5 °C.
    #expect(SMCConnection.decode(type: "sp78", bytes: [42, 128]) == 42.5)
    // fpe2: 14-bit unsigned, two fractional bits dropped — 2400 RPM.
    #expect(SMCConnection.decode(type: "fpe2", bytes: [0x25, 0x80]) == 2400)
    #expect(SMCConnection.decode(type: "ui16", bytes: [0x01, 0x00]) == 256)
}

@Test func refusesEncodingsItDoesNotUnderstand() {
    #expect(SMCConnection.decode(type: "wxyz", bytes: [1, 2, 3, 4]) == nil)
    // Truncated payloads must not be read past their end.
    #expect(SMCConnection.decode(type: "flt ", bytes: [0x00]) == nil)
    #expect(SMCConnection.decode(type: "ioft", bytes: [0x00, 0x01]) == nil)
}
