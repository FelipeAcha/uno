import Foundation

public enum OfflineFindingState: String { case separated = "SEPARATED"; case nearby = "NEARBY" }

public struct OfflineFindingFrame {
    public let state: OfflineFindingState
    public let publicKeyPayload: Data?
    public let statusByte: UInt8
    public let hintByte: UInt8?
    public let rawManufacturerData: Data

    public var deviceType: String {
        switch (statusByte >> 4) & 0b11 {
        case 0: return "Apple Device"
        case 1: return "AirTag"
        case 2: return "Licensed 3rd Party Find My Device"
        case 3: return "AirPods"
        default: return "Unknown"
        }
    }
    public var batteryLevel: String {
        switch (statusByte >> 6) & 0b11 {
        case 0: return "Full"
        case 1: return "Medium"
        case 2: return "Low"
        case 3: return "Very Low"
        default: return "Unknown"
        }
    }

    public init?(manufacturerData data: Data) {
        guard data.count >= 6 else { return nil }
        guard data[0] == 0x4c, data[1] == 0x00, data[2] == 0x12 else { return nil }
        switch data[3] {
        case 0x19:
            guard data.count == 29 else { return nil }
            state = .separated; statusByte = data[4]
            publicKeyPayload = data.subdata(in: 5..<27); hintByte = data[28]
            rawManufacturerData = data
        case 0x02:
            guard data.count == 6 else { return nil }
            state = .nearby; statusByte = data[4]
            publicKeyPayload = nil; hintByte = nil; rawManufacturerData = data
        default: return nil
        }
    }
}

public func median(_ v: [Double]) -> Double { let s=v.sorted(); guard !s.isEmpty else { return -999 }; let m=s.count/2; return s.count%2==1 ? s[m] : (s[m-1]+s[m])/2 }
public func proximityScore(_ rssi: Double) -> Int { Int(max(0,min(100,round(((rssi+95)/60)*100)))) }
