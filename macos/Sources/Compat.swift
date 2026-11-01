import Foundation

// UUID(CFUUID) is missing from the macOS 15.4 SDK (Xcode 16.3); upstream builds on Xcode 26.
extension UUID {
    init(_ cfuuid: CFUUID) {
        let b = CFUUIDGetUUIDBytes(cfuuid)
        self.init(uuid: (b.byte0, b.byte1, b.byte2, b.byte3, b.byte4, b.byte5, b.byte6, b.byte7,
                         b.byte8, b.byte9, b.byte10, b.byte11, b.byte12, b.byte13, b.byte14, b.byte15))
    }
}
