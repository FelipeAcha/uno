import Cocoa
import CoreBluetooth

@main
struct ProbeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--compile-only") { return }
        app.run()
    }
}

final class ProbeDelegate: NSObject, NSApplicationDelegate, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    func applicationDidFinishLaunching(_ notification: Notification) {
        central = CBCentralManager(delegate: self, queue: DispatchQueue.main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            central.stopScan()
        }
        NSApp.terminate(nil)
    }
}
