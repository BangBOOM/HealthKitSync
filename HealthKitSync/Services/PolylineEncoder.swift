import CoreLocation
import Foundation

enum PolylineEncoder {
    static func encode(_ locations: [CLLocation]) -> String? {
        guard !locations.isEmpty else { return nil }
        var output = ""
        var previousLatitude = 0
        var previousLongitude = 0

        for location in locations {
            let latitude = Int((location.coordinate.latitude * 100_000).rounded())
            let longitude = Int((location.coordinate.longitude * 100_000).rounded())
            output += encodeValue(latitude - previousLatitude)
            output += encodeValue(longitude - previousLongitude)
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return output
    }

    private static func encodeValue(_ value: Int) -> String {
        var transformed = value < 0 ? ~(value << 1) : value << 1
        var output = ""
        while transformed >= 0x20 {
            let scalar = UnicodeScalar((0x20 | (transformed & 0x1f)) + 63)!
            output.unicodeScalars.append(scalar)
            transformed >>= 5
        }
        output.unicodeScalars.append(UnicodeScalar(transformed + 63)!)
        return output
    }
}

