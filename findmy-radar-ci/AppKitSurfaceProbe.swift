import Cocoa
import CoreBluetooth
import Foundation

final class SurfaceProbe: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    var central: CBCentralManager!
    var timer: Timer?
    var file: FileHandle?
    let root = NSStackView()
    let table = NSTableView()
    let progress = NSProgressIndicator()
    let label = NSTextField(labelWithString: "Bluetooth")
    let check = NSButton(checkboxWithTitle: "Mission filter", target: nil, action: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        root.orientation = .vertical
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.addArrangedSubview(label)
        root.addArrangedSubview(check)
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        root.addArrangedSubview(progress)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rssi"))
        col.title = "RSSI"
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        root.addArrangedSubview(table)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)

        ProcessInfo.processInfo.disableAutomaticTermination("BLE recovery scan")
        ProcessInfo.processInfo.disableSuddenTermination()
        central = CBCentralManager(delegate: self, queue: DispatchQueue.main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if central?.isScanning == true { central.stopScan() }
        try? file?.synchronize()
        try? file?.close()
        ProcessInfo.processInfo.enableSuddenTermination()
        ProcessInfo.processInfo.enableAutomaticTermination("closed")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && !central.isScanning {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard RSSI.intValue != 127 else { return }
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        if data.count == 29 && data[0] == 0x4c && data[1] == 0x00 && data[2] == 0x12 && data[3] == 0x19 {
            label.stringValue = String(format: "%.1f dBm %@", RSSI.doubleValue, peripheral.identifier.uuidString)
        }
    }

    func refresh() {
        label.textColor = .systemGreen
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.backgroundColor = NSColor.clear.cgColor
        progress.doubleValue = 50
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 1 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let text = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        text.identifier = id
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.stringValue = "RSSI"
        return text
    }

    @objc func openLogs() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
    }
}
