import Foundation
import CoreBluetooth
import Darwin

struct OfflineFindingFrame {
    let publicKeyPayload: Data
    init?(manufacturerData data: Data) {
        guard data.count >= 29 else { return nil }
        guard data[0] == 0x4c, data[1] == 0x00 else { return nil }
        guard data[2] == 0x12, data[3] == 0x19 else { return nil }
        let key = data.subdata(in: 5..<27)
        guard key.count == 22 else { return nil }
        publicKeyPayload = key
    }
}

final class TerminalRawMode {
    private var original = termios()
    private var enabled = false
    func enable() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        if tcgetattr(STDIN_FILENO, &original) != 0 { return }
        var raw = original
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        if tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 {
            let flags = fcntl(STDIN_FILENO, F_GETFL)
            _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)
            enabled = true
        }
    }
    func disable() {
        guard enabled else { return }
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        _ = fcntl(STDIN_FILENO, F_SETFL, flags & ~O_NONBLOCK)
        enabled = false
    }
    func readKey() -> Character? {
        var byte: UInt8 = 0
        let n = Darwin.read(STDIN_FILENO, &byte, 1)
        guard n == 1 else { return nil }
        return Character(UnicodeScalar(byte))
    }
}

final class Probe: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: DispatchQueue.main)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        guard let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        _ = OfflineFindingFrame(manufacturerData: manufacturer)
        _ = RSSI.doubleValue
    }
}

func selfTest() {
    var frame = Data([0x4c, 0x00, 0x12, 0x19, 0x00])
    frame.append(Data((0..<22).map(UInt8.init)))
    frame.append(contentsOf: [0x00, 0x00])
    precondition(frame.count == 29)
    precondition(OfflineFindingFrame(manufacturerData: frame) != nil)
}

selfTest()
print("compile-probe self-test pass")
