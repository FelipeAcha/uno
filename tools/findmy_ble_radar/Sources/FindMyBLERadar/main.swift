import Foundation
import RadarCore

#if os(macOS)
import AppKit
import CoreBluetooth

private struct CandidateSnapshot {
    let rollingIdentifier: String
    let shortIdentifier: String
    let medianRSSI: Double
    let meanRSSI: Double
    let trendDB: Double
    let score: Int
    let stabilityDB: Double
    let eventCount: Int
    let markHits: Int
    let firstSeen: Date
    let lastSeen: Date
    let rawManufacturerDataHex: String
}

private final class CandidateRecord {
    let rollingIdentifier: String
    let shortIdentifier: String
    let firstSeen: Date
    var lastSeen: Date
    var signal = SignalWindow(capacity: 36)
    var eventCount = 0
    var markHits = 0
    var rawManufacturerDataHex = ""

    init(advertisement: FindMyAdvertisement, rssi: Int, now: Date) {
        rollingIdentifier = advertisement.rollingIdentifier
        shortIdentifier = advertisement.shortIdentifier
        firstSeen = now
        lastSeen = now
        signal.add(rssi)
        eventCount = 1
        rawManufacturerDataHex = advertisement.rawManufacturerData.hexString
    }

    func add(advertisement: FindMyAdvertisement, rssi: Int, now: Date) {
        lastSeen = now
        signal.add(rssi)
        eventCount += 1
        rawManufacturerDataHex = advertisement.rawManufacturerData.hexString
    }

    func snapshot() -> CandidateSnapshot? {
        guard let stats = signal.statistics() else { return nil }
        return CandidateSnapshot(
            rollingIdentifier: rollingIdentifier,
            shortIdentifier: shortIdentifier,
            medianRSSI: stats.medianRSSI,
            meanRSSI: stats.meanRSSI,
            trendDB: stats.trendDB,
            score: stats.score,
            stabilityDB: stats.stabilityDB,
            eventCount: eventCount,
            markHits: markHits,
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            rawManufacturerDataHex: rawManufacturerDataHex
        )
    }
}

private final class CSVLogger {
    let fileURL: URL
    private let handle: FileHandle
    private let formatter = ISO8601DateFormatter()

    init?() {
        do {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
            let dir = docs.appendingPathComponent("FindMy BLE Radar Logs", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let stamp = Self.fileStamp(Date())
            fileURL = dir.appendingPathComponent("findmy_ble_radar_\(stamp).csv")
            fm.createFile(atPath: fileURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: fileURL)
            writeLine("timestamp_local,event,fingerprint,rssi_dbm,median_rssi_dbm,score,trend_db,stability_db,event_count,mark_hits,manufacturer_data_hex")
        } catch {
            return nil
        }
    }

    deinit {
        try? handle.close()
    }

    func logAdvertisement(_ snapshot: CandidateSnapshot, rssi: Int) {
        writeLine([
            formatter.string(from: Date()),
            "ADVERTISEMENT",
            snapshot.shortIdentifier,
            String(rssi),
            String(format: "%.1f", snapshot.medianRSSI),
            String(snapshot.score),
            String(format: "%.1f", snapshot.trendDB),
            String(format: "%.1f", snapshot.stabilityDB),
            String(snapshot.eventCount),
            String(snapshot.markHits),
            snapshot.rawManufacturerDataHex
        ].joined(separator: ","))
    }

    func logMark(active: [CandidateSnapshot]) {
        let summary = active.map { "\($0.shortIdentifier):\(Int($0.medianRSSI.rounded()))" }.joined(separator: "|")
        writeLine([formatter.string(from: Date()), "FIND_MY_MARK", summary, "", "", "", "", "", "", "", ""].joined(separator: ","))
    }

    func logStatus(_ text: String) {
        let safe = text.replacingOccurrences(of: ",", with: ";")
        writeLine([formatter.string(from: Date()), "STATUS", safe, "", "", "", "", "", "", "", ""].joined(separator: ","))
    }

    private func writeLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging failure must never terminate the recovery scan.
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: date)
    }
}

private protocol BluetoothRadarDelegate: AnyObject {
    func radarStatusChanged(_ status: String, isScanning: Bool)
    func radarCandidatesChanged()
}

private final class BluetoothRadar: NSObject, CBCentralManagerDelegate {
    weak var delegate: BluetoothRadarDelegate?

    private(set) var candidates: [String: CandidateRecord] = [:]
    private(set) var pinnedIdentifier: String?
    private(set) var isScanning = false
    private(set) var statusText = "Initializing Bluetooth..."

    private var manager: CBCentralManager!
    private let logger = CSVLogger()
    private let staleAfter: TimeInterval = 9.0

    override init() {
        super.init()
        manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanningIfNeeded()
        case .poweredOff:
            stopScanningIfNeeded()
            updateStatus("BLUETOOTH OFF — turn Bluetooth on. Radar will start automatically.", scanning: false)
        case .unauthorized:
            stopScanningIfNeeded()
            updateStatus("BLUETOOTH NOT AUTHORIZED — enable FindMy BLE Radar in System Settings > Privacy & Security > Bluetooth.", scanning: false)
        case .unsupported:
            stopScanningIfNeeded()
            updateStatus("Bluetooth Low Energy is not supported on this Mac.", scanning: false)
        case .resetting:
            stopScanningIfNeeded()
            updateStatus("Bluetooth is resetting — waiting for the system service...", scanning: false)
        case .unknown:
            stopScanningIfNeeded()
            updateStatus("Bluetooth state is not ready yet — waiting...", scanning: false)
        @unknown default:
            stopScanningIfNeeded()
            updateStatus("Unknown Bluetooth state — waiting...", scanning: false)
        }
    }

    private func startScanningIfNeeded() {
        guard !isScanning else { return }
        manager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        updateStatus("SCANNING — Apple Offline Finding BLE advertisements only", scanning: true)
    }

    private func stopScanningIfNeeded() {
        if isScanning {
            manager.stopScan()
        }
        isScanning = false
    }

    func restartScan() {
        guard manager.state == .poweredOn else {
            centralManagerDidUpdateState(manager)
            return
        }
        manager.stopScan()
        isScanning = false
        startScanningIfNeeded()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        guard rssi < 0, rssi >= -127 else { return }
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            return
        }
        guard let findMy = FindMyAdvertisementParser.parse(manufacturerData: manufacturerData) else {
            return
        }

        let now = Date()
        let id = findMy.rollingIdentifier
        let record: CandidateRecord
        if let existing = candidates[id] {
            existing.add(advertisement: findMy, rssi: rssi, now: now)
            record = existing
        } else {
            let new = CandidateRecord(advertisement: findMy, rssi: rssi, now: now)
            candidates[id] = new
            record = new
        }

        if let snap = record.snapshot() {
            logger?.logAdvertisement(snap, rssi: rssi)
        }
        delegate?.radarCandidatesChanged()
    }

    func activeSnapshots(now: Date = Date()) -> [CandidateSnapshot] {
        candidates.values
            .compactMap { $0.snapshot() }
            .filter { now.timeIntervalSince($0.lastSeen) <= staleAfter }
            .sorted { a, b in
                if a.rollingIdentifier == pinnedIdentifier { return true }
                if b.rollingIdentifier == pinnedIdentifier { return false }
                if a.markHits != b.markHits { return a.markHits > b.markHits }
                if a.score != b.score { return a.score > b.score }
                return a.medianRSSI > b.medianRSSI
            }
    }

    func pin(_ rollingIdentifier: String?) {
        pinnedIdentifier = rollingIdentifier
        delegate?.radarCandidatesChanged()
    }

    func markOfficialFindMyUpdate() -> [CandidateSnapshot] {
        let active = activeSnapshots()
        for snapshot in active {
            candidates[snapshot.rollingIdentifier]?.markHits += 1
        }
        let updated = activeSnapshots()
        logger?.logMark(active: updated)
        delegate?.radarCandidatesChanged()
        return updated
    }

    private func updateStatus(_ text: String, scanning: Bool) {
        statusText = text
        isScanning = scanning
        logger?.logStatus(text)
        delegate?.radarStatusChanged(text, isScanning: scanning)
    }
}

private final class SignalGaugeView: NSView {
    var score: Int = 0 { didSet { needsDisplay = true } }
    var flashOn = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 4, dy: 4)
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        bg.fill()

        let fraction = CGFloat(max(0, min(100, score))) / 100.0
        let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * fraction, height: bounds.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 12, yRadius: 12)

        let fillColor: NSColor
        switch score {
        case 80...: fillColor = .systemRed
        case 60...: fillColor = .systemOrange
        case 40...: fillColor = .systemYellow
        default: fillColor = .systemBlue
        }
        fillColor.withAlphaComponent(flashOn ? 0.95 : 0.70).setFill()
        fillPath.fill()

        NSColor.separatorColor.setStroke()
        bg.lineWidth = 1
        bg.stroke()
    }
}

private final class RadarViewController: NSViewController, BluetoothRadarDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let radar = BluetoothRadar()
    private var snapshots: [CandidateSnapshot] = []
    private var refreshTimer: Timer?
    private var flashState = false
    private var soundEnabled = false
    private var lastBeep = Date.distantPast
    private var lastMarkText = "No official Find My mark recorded in this session."

    private let statusLabel = NSTextField(labelWithString: "Initializing...")
    private let candidateCountLabel = NSTextField(labelWithString: "0 active candidates")
    private let targetLabel = NSTextField(labelWithString: "No target pinned")
    private let scoreLabel = NSTextField(labelWithString: "—")
    private let bandLabel = NSTextField(labelWithString: "DISCOVERY MODE")
    private let rssiLabel = NSTextField(labelWithString: "RSSI: —")
    private let trendLabel = NSTextField(labelWithString: "Trend: —")
    private let stabilityLabel = NSTextField(labelWithString: "Stability: —")
    private let markLabel = NSTextField(labelWithString: "No official Find My mark recorded in this session.")
    private let gauge = SignalGaugeView(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let pinButton = NSButton(title: "Pin selected", target: nil, action: nil)
    private let unpinButton = NSButton(title: "Unpin", target: nil, action: nil)
    private let markButton = NSButton(title: "MARK: official Find My updated now", target: nil, action: nil)
    private let soundButton = NSButton(title: "Sound: OFF", target: nil, action: nil)
    private let restartButton = NSButton(title: "Restart scan", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1050, height: 760))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        radar.delegate = self
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func buildUI() {
        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        candidateCountLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        targetLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 72, weight: .bold)
        scoreLabel.alignment = .center
        bandLabel.font = .systemFont(ofSize: 22, weight: .bold)
        bandLabel.alignment = .center
        rssiLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        rssiLabel.alignment = .center
        trendLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        trendLabel.alignment = .center
        stabilityLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        stabilityLabel.alignment = .center
        markLabel.font = .systemFont(ofSize: 12)
        markLabel.textColor = .secondaryLabelColor
        markLabel.lineBreakMode = .byWordWrapping
        markLabel.maximumNumberOfLines = 2

        gauge.translatesAutoresizingMaskIntoConstraints = false
        gauge.heightAnchor.constraint(equalToConstant: 54).isActive = true

        pinButton.target = self
        pinButton.action = #selector(pinSelected)
        unpinButton.target = self
        unpinButton.action = #selector(unpin)
        markButton.target = self
        markButton.action = #selector(markFindMy)
        soundButton.target = self
        soundButton.action = #selector(toggleSound)
        restartButton.target = self
        restartButton.action = #selector(restartScan)

        let controls = NSStackView(views: [pinButton, unpinButton, markButton, soundButton, restartButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.distribution = .fillProportionally

        let top = NSStackView(views: [statusLabel, candidateCountLabel])
        top.orientation = .horizontal
        top.distribution = .fillEqually

        let targetPanel = NSStackView(views: [targetLabel, scoreLabel, gauge, bandLabel, rssiLabel, trendLabel, stabilityLabel, markLabel])
        targetPanel.orientation = .vertical
        targetPanel.spacing = 7
        targetPanel.alignment = .centerX

        configureTable()
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

        let note = NSTextField(wrappingLabelWithString:
            "Only Apple Offline Finding manufacturer advertisements (4C00 / 0x12 / 0x19) are listed. " +
            "RSSI is relative, not meters. A fingerprint rotates with Apple's Find My key and is not a permanent device ID. " +
            "Keep the Mac awake with the lid open. This app scans only; it never connects, pairs, writes, or sends commands to a nearby device."
        )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let root = NSStackView(views: [top, targetPanel, controls, scroll, note])
        root.orientation = .vertical
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            gauge.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.78)
        ])
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 24

        let columns: [(String, String, CGFloat)] = [
            ("id", "Fingerprint", 120),
            ("rssi", "Median RSSI", 105),
            ("score", "Score", 75),
            ("trend", "Trend dB", 90),
            ("stability", "Stability", 85),
            ("age", "Age", 70),
            ("events", "Events", 70),
            ("marks", "Find My marks", 105)
        ]
        for (id, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = 60
            tableView.addTableColumn(col)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshots.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < snapshots.count, let tableColumn else { return nil }
        let snapshot = snapshots[row]
        let id = tableColumn.identifier.rawValue
        let identifier = NSUserInterfaceItemIdentifier("cell-\(id)")

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView(frame: .zero)
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        switch id {
        case "id":
            let pin = snapshot.rollingIdentifier == radar.pinnedIdentifier ? "★ " : ""
            cell.textField?.stringValue = pin + snapshot.shortIdentifier
        case "rssi": cell.textField?.stringValue = String(format: "%.1f dBm", snapshot.medianRSSI)
        case "score": cell.textField?.stringValue = "\(snapshot.score)/100"
        case "trend": cell.textField?.stringValue = String(format: "%+.1f", snapshot.trendDB)
        case "stability": cell.textField?.stringValue = String(format: "±%.1f", snapshot.stabilityDB)
        case "age": cell.textField?.stringValue = String(format: "%.1fs", Date().timeIntervalSince(snapshot.lastSeen))
        case "events": cell.textField?.stringValue = String(snapshot.eventCount)
        case "marks": cell.textField?.stringValue = String(snapshot.markHits)
        default: cell.textField?.stringValue = ""
        }
        return cell
    }

    func radarStatusChanged(_ status: String, isScanning: Bool) {
        statusLabel.stringValue = status
        statusLabel.textColor = isScanning ? .systemGreen : .systemOrange
    }

    func radarCandidatesChanged() {
        refreshUI()
    }

    private func refreshUI() {
        snapshots = radar.activeSnapshots()
        candidateCountLabel.stringValue = "\(snapshots.count) active Find My candidate\(snapshots.count == 1 ? "" : "s")"
        tableView.reloadData()

        guard let pinnedID = radar.pinnedIdentifier else {
            renderDiscoveryMode()
            return
        }
        guard let target = snapshots.first(where: { $0.rollingIdentifier == pinnedID }) else {
            renderMissingTarget(pinnedID)
            return
        }
        renderTarget(target)
    }

    private func renderDiscoveryMode() {
        targetLabel.stringValue = "No target pinned — discovery mode"
        scoreLabel.stringValue = "—"
        bandLabel.stringValue = snapshots.count == 1 ? "ONE ACTIVE CANDIDATE" : "DISCOVERY MODE"
        rssiLabel.stringValue = "RSSI: —"
        trendLabel.stringValue = "Trend: —"
        stabilityLabel.stringValue = snapshots.count == 1
            ? "If official Find My updates now, mark it and consider pinning the single candidate."
            : "Select a candidate only after correlation; strongest does not automatically mean yours."
        gauge.score = snapshots.first?.score ?? 0
        gauge.flashOn = false
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        markLabel.stringValue = lastMarkText
    }

    private func renderMissingTarget(_ pinnedID: String) {
        targetLabel.stringValue = "Pinned target temporarily not visible: \(String(pinnedID.prefix(10)).uppercased())"
        scoreLabel.stringValue = "—"
        bandLabel.stringValue = "OUT OF RANGE / NOT ADVERTISING / KEY MAY HAVE ROTATED"
        rssiLabel.stringValue = "RSSI: —"
        trendLabel.stringValue = "Do not auto-link a new fingerprint. Re-correlate."
        stabilityLabel.stringValue = ""
        gauge.score = 0
        gauge.flashOn = false
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        markLabel.stringValue = lastMarkText
    }

    private func renderTarget(_ target: CandidateSnapshot) {
        let band = SignalWindow.band(for: target.score)
        let trend = SignalWindow.trendLabel(target.trendDB)
        targetLabel.stringValue = "TRACKING \(target.shortIdentifier)  •  Find My marks: \(target.markHits)"
        scoreLabel.stringValue = "\(target.score)"
        bandLabel.stringValue = band
        rssiLabel.stringValue = String(format: "RSSI median: %.1f dBm", target.medianRSSI)
        trendLabel.stringValue = String(format: "%@  %+.1f dB", trend, target.trendDB)
        stabilityLabel.stringValue = String(format: "Noise/stability: ±%.1f dB  •  events: %d", target.stabilityDB, target.eventCount)
        gauge.score = target.score
        markLabel.stringValue = lastMarkText

        let shouldFlash = target.score >= 84
        if shouldFlash {
            flashState.toggle()
            gauge.flashOn = flashState
            view.layer?.backgroundColor = (flashState
                ? NSColor.systemRed.withAlphaComponent(0.12)
                : NSColor.windowBackgroundColor).cgColor
        } else {
            gauge.flashOn = false
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }

        maybeBeep(score: target.score)
    }

    private func maybeBeep(score: Int) {
        guard soundEnabled else { return }
        let interval: TimeInterval
        switch score {
        case 85...: interval = 0.25
        case 70...: interval = 0.50
        case 55...: interval = 0.85
        case 40...: interval = 1.30
        default: interval = 2.20
        }
        let now = Date()
        if now.timeIntervalSince(lastBeep) >= interval {
            lastBeep = now
            NSSound.beep()
        }
    }

    @objc private func pinSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < snapshots.count else { return }
        radar.pin(snapshots[row].rollingIdentifier)
    }

    @objc private func unpin() {
        radar.pin(nil)
    }

    @objc private func markFindMy() {
        let active = radar.markOfficialFindMyUpdate()
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        if active.isEmpty {
            lastMarkText = "\(stamp): official Find My marked, but no Offline Finding candidate was active at that instant."
        } else if active.count == 1 {
            lastMarkText = "\(stamp): official Find My marked. Exactly ONE active candidate: \(active[0].shortIdentifier). Strong correlation candidate."
            if radar.pinnedIdentifier == nil {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        } else {
            let ids = active.prefix(5).map { "\($0.shortIdentifier)(\(Int($0.medianRSSI.rounded())))" }.joined(separator: ", ")
            lastMarkText = "\(stamp): official Find My marked with \(active.count) active candidates: \(ids)."
        }
        refreshUI()
    }

    @objc private func toggleSound() {
        soundEnabled.toggle()
        soundButton.title = soundEnabled ? "Sound: ON" : "Sound: OFF"
    }

    @objc private func restartScan() {
        radar.restartScan()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Active BLE recovery scan"
        )

        let controller = RadarViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1050, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FindMy BLE Radar v3 — Visual Proximity"
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = appDelegate
app.run()

#else
print("FindMy BLE Radar v3 requires macOS. RadarCore unit tests can run on other platforms.")
#endif
