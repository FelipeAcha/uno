import Foundation

#if canImport(CoreBluetooth)
import CoreBluetooth
import Darwin
#endif

// MARK: - Cross-platform core logic

struct OfflineFindingFrame {
    let publicKeyPayload: Data
    let rawManufacturerData: Data

    init?(manufacturerData data: Data) {
        // OpenHaystack / SEEMOO observed layout from CoreBluetooth manufacturer data:
        // 0..1 Apple company ID 0x004C -> bytes 4C 00
        // 2    Offline Finding subtype 0x12
        // 3    subtype length 0x19
        // 4    state byte
        // 5..26 public-key payload fragment (22 bytes)
        // 27..  trailing bits/hint depending on frame details.
        guard data.count >= 29 else { return nil }
        guard data[0] == 0x4c, data[1] == 0x00 else { return nil }
        guard data[2] == 0x12, data[3] == 0x19 else { return nil }
        let key = data.subdata(in: 5..<27)
        guard key.count == 22 else { return nil }
        self.publicKeyPayload = key
        self.rawManufacturerData = data
    }
}

func fnv1a64(_ data: Data) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return hash
}

func fingerprint(_ data: Data) -> String {
    String(format: "%010llx", fnv1a64(data) & 0xffffffffff)
}

func clamp<T: Comparable>(_ value: T, _ lo: T, _ hi: T) -> T {
    min(max(value, lo), hi)
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return -999 }
    let s = values.sorted()
    let m = s.count / 2
    if s.count % 2 == 1 { return s[m] }
    return (s[m - 1] + s[m]) / 2.0
}

func proximityScore(rssi: Double) -> Int {
    // A deliberately relative scale, not meters.
    // -95 dBm -> 0, -35 dBm -> 100.
    let score = ((rssi + 95.0) / 60.0) * 100.0
    return Int(clamp(score.rounded(), 0.0, 100.0))
}

func strengthBand(score: Int) -> String {
    switch score {
    case 88...: return "EXTREMELY STRONG"
    case 75...: return "VERY STRONG"
    case 60...: return "STRONG"
    case 45...: return "MEDIUM"
    case 28...: return "WEAK"
    default: return "VERY WEAK"
    }
}

func gauge(_ score: Int, width: Int = 46) -> String {
    let filled = Int((Double(width) * Double(clamp(score, 0, 100)) / 100.0).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: max(0, width - filled))
}

final class Candidate {
    let id: String
    var samples: [(time: TimeInterval, rssi: Double)] = []
    var firstSeen: TimeInterval
    var lastSeen: TimeInterval
    var count: Int = 0
    var ema: Double?
    var peak: Double = -999

    init(id: String, now: TimeInterval) {
        self.id = id
        self.firstSeen = now
        self.lastSeen = now
    }

    func add(rssi: Double, now: TimeInterval) {
        count += 1
        lastSeen = now
        samples.append((now, rssi))
        // Keep ~60 seconds of history plus a hard cap.
        samples.removeAll { now - $0.time > 60 }
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }
        if let old = ema {
            ema = 0.28 * rssi + 0.72 * old
        } else {
            ema = rssi
        }
        peak = max(peak, rssi)
    }

    var recentValues: [Double] {
        let cutoff = Date().timeIntervalSince1970 - 12.0
        let vals = samples.filter { $0.time >= cutoff }.map { $0.rssi }
        return vals.isEmpty ? samples.suffix(12).map { $0.rssi } : vals
    }

    var robustRSSI: Double { median(recentValues) }

    var trendDB: Double {
        let vals = recentValues
        guard vals.count >= 8 else { return 0 }
        let split = vals.count / 2
        return median(Array(vals[split...])) - median(Array(vals[..<split]))
    }

    var score: Int { proximityScore(rssi: robustRSSI) }
}

func selfTest() -> Bool {
    // Parser test from known OpenHaystack frame shape.
    var data = Data([0x4c, 0x00, 0x12, 0x19, 0x00])
    data.append(Data((0..<22).map { UInt8($0) }))
    data.append(contentsOf: [0x00, 0x00])
    guard data.count == 29 else { return false }
    guard let f = OfflineFindingFrame(manufacturerData: data) else { return false }
    guard f.publicKeyPayload.count == 22 else { return false }
    guard OfflineFindingFrame(manufacturerData: Data([0x4c,0x00,0x10,0x19] + Array(repeating: 0, count: 25))) == nil else { return false }
    guard proximityScore(rssi: -95) == 0 else { return false }
    guard proximityScore(rssi: -35) == 100 else { return false }
    guard median([1,2,3]) == 2 else { return false }
    guard median([1,2,3,4]) == 2.5 else { return false }
    return true
}

#if canImport(CoreBluetooth)

// MARK: - macOS native scanner

let ANSI_CLEAR = "\u{001B}[2J\u{001B}[H"
let ANSI_BOLD = "\u{001B}[1m"
let ANSI_DIM = "\u{001B}[2m"
let ANSI_RESET = "\u{001B}[0m"
let ANSI_REVERSE = "\u{001B}[7m"
let ANSI_HIDE_CURSOR = "\u{001B}[?25l"
let ANSI_SHOW_CURSOR = "\u{001B}[?25h"

final class TerminalRawMode {
    private var original = termios()
    private var enabled = false

    func enable() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        if tcgetattr(STDIN_FILENO, &original) != 0 { return }
        var raw = original
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        // O_NONBLOCK below makes reads non-blocking; avoid relying on platform-specific
        // c_cc tuple indexes for VMIN/VTIME.
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

    deinit { disable() }
}

final class Radar: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private var candidates: [String: Candidate] = [:]
    private var selectedID: String?
    private var timer: Timer?
    private var csvHandle: FileHandle?
    private let terminal = TerminalRawMode()
    private var running = true
    private var beepEnabled = false
    private var lastBeep = Date.distantPast.timeIntervalSince1970
    private var lastFindMyMark: String?
    private var snapshotCounter = 0
    private var applePacketCount = 0
    private var offlinePacketCount = 0
    private var bluetoothStateText = "INITIALIZING"
    private let startTime = Date().timeIntervalSince1970

    override init() {
        super.init()
        terminal.enable()
        print(ANSI_HIDE_CURSOR, terminator: "")
        setupLog()
        central = CBCentralManager(delegate: self, queue: DispatchQueue.main)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit { cleanup() }

    private func setupLog() {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: fm.currentDirectoryPath)
        let logs = base.appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
        let url = logs.appendingPathComponent("findmy_ble_native_\(fmt.string(from: Date())).csv")
        fm.createFile(atPath: url.path, contents: nil)
        csvHandle = try? FileHandle(forWritingTo: url)
        writeCSV("timestamp,event,candidate,rssi,robust_rssi,score,trend_db,count,note\n")
    }

    private func writeCSV(_ line: String) {
        if let d = line.data(using: .utf8) { try? csvHandle?.write(contentsOf: d) }
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStateText = "ON / SCANNING"
            central.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .poweredOff:
            bluetoothStateText = "OFF — TURN BLUETOOTH ON"
        case .unauthorized:
            bluetoothStateText = "UNAUTHORIZED — CHECK PRIVACY > BLUETOOTH"
        case .unsupported:
            bluetoothStateText = "UNSUPPORTED"
        case .resetting:
            bluetoothStateText = "RESETTING"
        case .unknown:
            bluetoothStateText = "UNKNOWN"
        @unknown default:
            bluetoothStateText = "UNKNOWN"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        guard let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        if manufacturer.count >= 2 && manufacturer[0] == 0x4c && manufacturer[1] == 0x00 {
            applePacketCount += 1
        }
        guard let frame = OfflineFindingFrame(manufacturerData: manufacturer) else { return }
        offlinePacketCount += 1
        let id = fingerprint(frame.publicKeyPayload)
        let now = Date().timeIntervalSince1970
        let c = candidates[id] ?? Candidate(id: id, now: now)
        c.add(rssi: RSSI.doubleValue, now: now)
        candidates[id] = c
        writeCSV("\(isoNow()),sample,\(id),\(RSSI.doubleValue),\(String(format: "%.1f", c.robustRSSI)),\(c.score),\(String(format: "%.1f", c.trendDB)),\(c.count),\n")
    }

    private func activeCandidates(now: TimeInterval) -> [Candidate] {
        candidates.values
            .filter { now - $0.lastSeen <= 8.0 }
            .sorted { $0.robustRSSI > $1.robustRSSI }
    }

    private func tick() {
        guard running else { return }
        let now = Date().timeIntervalSince1970
        let active = activeCandidates(now: now)
        handleKey(active: active)
        render(active: active, now: now)
        maybeBeep(now: now)
    }

    private func handleKey(active: [Candidate]) {
        guard let ch = terminal.readKey() else { return }
        let k = String(ch).lowercased()
        if k == "q" {
            running = false
            cleanup()
            exit(0)
        } else if k == "u" {
            selectedID = nil
            writeCSV("\(isoNow()),unpin,,,,,,,\n")
        } else if k == "b" {
            beepEnabled.toggle()
        } else if k == "m" {
            lastFindMyMark = clockNow()
            let ids = active.map { "\($p0.id):\(String(format: "%.1f", $0.robustRSSI))" }.joined(separator: "|")
            writeCSV("\(isoNow()),FIND_MY_MARK,,,,,,,\(ids)\n")
        } else if k == "c" {
            snapshotCounter += 1
            let ids = active.map { "\($0.id):\(String(format: "%.1f", $0.robustRSSI)" }.joined(separator: "|")
            writeCSV("\(isoNow()),POSITION_P\(snapshotCounter),,,,,,,\(ids)\n")
        } else if let n = Int(k), n >= 1, n <= 9, n <= active.count {
            selectedID = active[n - 1].id
            writeCSV("\(isoNow()),pin,\(selectedID!),,,,,,,\n")
        }
    }

    private func maybeBeep(now: TimeInterval) {
        guard beepEnabled, let id = selectedID,
              let c = candidates[id], now - c.lastSeen <= 8 else { return }
        let interval = clamp(2.4 - Double(c.score) * 0.0215, 0.22, 2.4)
        if now - lastBeep >= interval {
            lastBeep = now
            print("\u{0007}", terminator: "")
            fflush(stdout)
        }
    }

    private func clockNow() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    private func trendText(_ d: Double) -> String {
        if d >= 5 { return "HOTTER  +\(String(format: "%.1f", d)) dB" }
        if d >= 2 { return "warmer  +\(String(format: "%.1f", d)) dB" }
        if d <= -5 { return "COLDER  \(String(format: "%.1f", d)) dB" }
        if d <= -2 { return "cooler  \(String(format: "%.1f", d)) dB" }
        return "stable  \(String(format: "%+.1f", d)) dB"
    }

    private func render(active: [Candidate], now: TimeInterval) {
        var out: [String] = []
        var flash = false
        if let id = selectedID, let c = candidates[id], now - c.lastSeen <= 8, c.score >= 84 {
            flash = Int(now * 2.0) % 2 == 0
        }
        out.append(ANSI_CLEAR + (flash ? ANSI_REVERSE : "") + " FINDMY BLE RADAR v3 — NATIVE macOS " + (flash ? ANSI_RESET : ""))
        out.append(String(repeating: "=", count: 68))
        out.append("Time: \(clockNow())    Bluetooth: \(bluetoothStateText)")
        out.append("Apple packets: \(applePacketCount)   Offline Finding 0x12: \(offlinePacketCount)   Active: \(active.count)")
        out.append("Mode: discovery only — NO connect / pair / write / Find My changes")
        out.append("")

        if let id = selectedID {
            if let c = candidates[id], now - c.lastSeen <= 8 {
                let score = c.score
                out.append("\(ANSI_BOLD)TRACKING WINDOW-ID: \(id)\(ANSI_RESET)")
                out.append("\(ANSI_BOLD)PROXIMITY [\(gauge(score))] \(score)/100\(ANSI_RESET)")
                out.append("Signal: \(String(format: "%.1f", c.robustRSSI)) dBm   \(strengthBand(score))")
                out.append("Trend:  \(trendText(c.trendDB))")
                out.append("Peak raw RSSI this key-window: \(String(format: "%.1f", c.peak)) dBm   Events: \(c.count)")
                if score >= 84 {
                    out.append("\(ANSI_REVERSE) ███ VERY HOT — compare from another public-side position ███ \(ANSI_RESET)")
                } else if c.trendDB >= 4 {
                    out.append(">>> HOTTER — signal is strengthening <<<")
                } else if c.trendDB <= -4 {
                    out.append("<<< COLDER — signal is weakening >>>")
                } else {
                    out.append("Hold 10–20 s for a robust median, then move a short distance.")
                }
            } else {
                out.append("\(ANSI_BOLD)TARGET \(id) NOT CURRENTLY VISIBLE\(ANSI_RESET)")
                out.append("Out of range / shielded / stopped advertising / rolling key changed.")
                out.append("Do NOT automatically assume a new ID is the same iPhone.")
            }
        } else {
            out.append("\(ANSI_BOLD)DISCOVERY MODE — no candidate pinned\(ANSI_RESET)")
            if active.count == 1 && active[0].count >= 3 {
                out.append("Only one active Offline Finding candidate: \(active[0].id). Press 1 to pin it.")
            } else if active.count > 1 {
                out.append("Multiple candidates present. Correlate with official Find My before pinning.")
            } else {
                out.append("No Offline Finding advertisement currently visible.")
            }
        }

        out.append("")
        out.append("ACTIVE OFFLINE FINDING CANDIDATES")
        out.append(" #   window-id    robust    score   trend      age     events")
        out.append("---  ----------   -------   -----   ---------  ------  ------")
        for (i, c) in active.prefix(9).enumerated() {
            let star = c.id == selectedID ? "*" : " "
            let idx = String(i + 1).padding(toLength: 2, withPad: " ", startingAt: 0)
            let cid = c.id.padding(toLength: 10, withPad: " ", startingAt: 0)
            let row = "\(star)\(idx)  \(cid)   "
                + String(format: "%6.1f   %3d/100   %+6.1f dB   %4.1fs   %5d",
                         c.robustRSSI, c.score, c.trendDB, now - c.lastSeen, c.count)
            out.append(row)
        }

        out.append("")
        out.append("KEYS: 1–9 pin | U unpin | M mark official Find My update | C position snapshot | B beep | Q quit")
        out.append("Beep: \(beepEnabled ? "ON" : "OFF")   Last Find My mark: \(lastFindMyMark ?? "—")   Position snapshots: \(snapshotCounter)")
        out.append("")
        out.append(ANSI_DIM + "Window-ID derives from the visible 22-byte public-key payload fragment. Apple rotates Find My keys ~15 min; this is NOT a permanent device identifier." + ANSI_RESET)
        out.append(ANSI_DIM + "RSSI is relative proximity only. Walls/metal/people/orientation/multipath can change it substantially." + ANSI_RESET)
        if bluetoothStateText.contains("OFF") {
            out.append("")
            out.append(ANSI_REVERSE + " BLUETOOTH IS OFF. Turn it on in Control Center or System Settings > Bluetooth. " + ANSI_RESET)
        }
        print(out.joined(separator: "\n"), terminator: "")
        fflush(stdout)
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        if central?.isScanning == true { central.stopScan() }
        try? csvHandle?.close()
        csvHandle = nil
        terminal.disable()
        print(ANSI_SHOW_CURSOR + ANSI_RESET)
        fflush(stdout)
    }
}

func runLive() {
    guard selfTest() else {
        fputs("Internal self-test FAILED. Do not use this build.\n", stderr)
        exit(2)
    }
    let radar = Radar()
    withExtendedLifetime(radar) {
        RunLoop.main.run()
    }
}

// MARK: - Demo

func runDemo() {
    print("FindMy BLE Radar v3 demo/self-test")
    guard selfTest() else {
        print("SELF-TEST FAILED")
        exit(2)
    }
    print("SELF-TEST PASS")
    print("\nVisual approximation:")
    for rssi in stride(from: -90.0, through: -40.0, by: 10.0) {
        let score = proximityScore(rssi: rssi)
        print(String(format: "%6.1f dBm  [%@] %3d/100  %@", rssi, gauge(score, width: 28), score, strengthBand(score)))
    }
    print("\nDemo does not access Bluetooth.")
}

let args = Set(CommandLine.arguments.dropFirst())
if args.contains("--demo") || args.contains("--self-test") {
    runDemo()
} else {
    runLive()
}

#else

// Linux/build-lab branch lets us compile/test all platform-neutral core logic.
if !selfTest() {
    fputs("SELF-TEST FAILED\n", stderr)
    exit(2)
}
print("SELF-TEST PASS (CoreBluetooth unavailable on this build host).")
for rssi in stride(from: -90.0, through: -40.0, by: 10.0) {
    let score = proximityScore(rssi: rssi)
    print("\(rssi) dBm -> \(score)/100 \(strengthBand(score: score))")
}

#endif
