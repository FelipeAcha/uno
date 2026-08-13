import Foundation

public struct FindMyAdvertisement: Equatable, Sendable {
    public let state: UInt8
    public let publicKeyPayload: Data
    public let trailingByte1: UInt8
    public let trailingByte2: UInt8
    public let rawManufacturerData: Data

    public init(
        state: UInt8,
        publicKeyPayload: Data,
        trailingByte1: UInt8,
        trailingByte2: UInt8,
        rawManufacturerData: Data
    ) {
        self.state = state
        self.publicKeyPayload = publicKeyPayload
        self.trailingByte1 = trailingByte1
        self.trailingByte2 = trailingByte2
        self.rawManufacturerData = rawManufacturerData
    }

    /// Full session/rolling-key identifier derived only from the public-key payload
    /// visible in the Find My BLE advertisement. Apple rotates this material, so it
    /// must never be treated as a permanent device identifier.
    public var rollingIdentifier: String {
        publicKeyPayload.hexString
    }

    public var shortIdentifier: String {
        String(rollingIdentifier.prefix(10)).uppercased()
    }
}

public enum FindMyAdvertisementParser {
    public static let appleCompanyID: [UInt8] = [0x4c, 0x00]
    public static let offlineFindingSubtype: UInt8 = 0x12
    public static let offlineFindingLength: UInt8 = 0x19
    public static let expectedManufacturerDataLength = 29
    public static let publicKeyPayloadLength = 22

    /// Parses the Apple Offline Finding manufacturer-data layout documented by
    /// OpenHaystack/SEEMOO for Find My BLE advertisements:
    /// 4c 00 | 12 | 19 | state | 22-byte public-key payload | 2 trailing bytes
    public static func parse(manufacturerData: Data) -> FindMyAdvertisement? {
        let bytes = [UInt8](manufacturerData)

        guard bytes.count == expectedManufacturerDataLength else {
            return nil
        }
        guard bytes[0] == appleCompanyID[0], bytes[1] == appleCompanyID[1] else {
            return nil
        }
        guard bytes[2] == offlineFindingSubtype else {
            return nil
        }
        guard bytes[3] == offlineFindingLength else {
            return nil
        }

        let keyStart = 5
        let keyEnd = keyStart + publicKeyPayloadLength
        guard keyEnd == 27 else {
            return nil
        }

        let keyPayload = Data(bytes[keyStart..<keyEnd])
        guard keyPayload.count == publicKeyPayloadLength else {
            return nil
        }

        return FindMyAdvertisement(
            state: bytes[4],
            publicKeyPayload: keyPayload,
            trailingByte1: bytes[27],
            trailingByte2: bytes[28],
            rawManufacturerData: manufacturerData
        )
    }
}

public struct SignalStatistics: Equatable, Sendable {
    public let medianRSSI: Double
    public let meanRSSI: Double
    public let trendDB: Double
    public let score: Int
    public let stabilityDB: Double
    public let sampleCount: Int

    public init(
        medianRSSI: Double,
        meanRSSI: Double,
        trendDB: Double,
        score: Int,
        stabilityDB: Double,
        sampleCount: Int
    ) {
        self.medianRSSI = medianRSSI
        self.meanRSSI = meanRSSI
        self.trendDB = trendDB
        self.score = score
        self.stabilityDB = stabilityDB
        self.sampleCount = sampleCount
    }
}

public struct SignalWindow: Sendable {
    private var values: [Int] = []
    public let capacity: Int

    public init(capacity: Int = 30) {
        self.capacity = max(8, capacity)
    }

    public var sampleCount: Int { values.count }
    public var rawValues: [Int] { values }

    public mutating func add(_ rssi: Int) {
        guard rssi < 0, rssi >= -127 else { return }
        values.append(rssi)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    public func statistics() -> SignalStatistics? {
        guard !values.isEmpty else { return nil }

        let doubles = values.map(Double.init)
        let median = Self.median(doubles)
        let mean = doubles.reduce(0, +) / Double(doubles.count)

        let half = max(1, values.count / 2)
        let older = Array(doubles.prefix(half))
        let newer = Array(doubles.suffix(half))
        let trend = values.count >= 8 ? Self.median(newer) - Self.median(older) : 0

        let absoluteDeviations = doubles.map { abs($0 - median) }
        let stability = Self.median(absoluteDeviations)

        return SignalStatistics(
            medianRSSI: median,
            meanRSSI: mean,
            trendDB: trend,
            score: Self.score(for: median),
            stabilityDB: stability,
            sampleCount: values.count
        )
    }

    /// Relative 0-100 proximity score. This is intentionally not a distance model.
    /// -95 dBm maps near zero and -35 dBm maps near 100.
    public static func score(for rssi: Double) -> Int {
        let normalized = (rssi + 95.0) / 60.0
        let clamped = min(1.0, max(0.0, normalized))
        return Int((clamped * 100.0).rounded())
    }

    public static func band(for score: Int) -> String {
        switch score {
        case 88...: return "EXTREMELY STRONG"
        case 75...: return "VERY STRONG"
        case 60...: return "STRONG"
        case 45...: return "MEDIUM"
        case 28...: return "WEAK"
        default: return "VERY WEAK"
        }
    }

    public static func trendLabel(_ trendDB: Double) -> String {
        if trendDB >= 5 { return "GETTING STRONGER" }
        if trendDB >= 2 { return "SLIGHTLY STRONGER" }
        if trendDB <= -5 { return "GETTING WEAKER" }
        if trendDB <= -2 { return "SLIGHTLY WEAKER" }
        return "STABLE"
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2.0
        }
        return sorted[middle]
    }
}

public extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
