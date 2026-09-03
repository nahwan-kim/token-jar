import CryptoKit
import CoreFoundation
import Foundation
import TokenTankDomain

public enum JSONScalar {
    /// JSONSerialization bridges booleans and numbers through NSNumber. Swift's
    /// `is Bool` bridge also classifies numeric 0 and 1 as Bool, so compare the
    /// Core Foundation type identity instead to keep source zero distinct.
    public static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

public enum StableSourceID {
    public static func make(prefix: String, components: [String]) -> RawQuotaID {
        let canonical = components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return RawQuotaID(rawValue: "\(prefix).\(digest)")
    }
}
