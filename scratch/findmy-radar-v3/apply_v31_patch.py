from pathlib import Path

p = Path('scratch/findmy-radar-v3/FindMyBLERadar.swift')
s = p.read_text()

# Baseline syntax corrections discovered by macOS 26 CI.
s = s.replace('$p0.id', '$0.id')
s = s.replace(
    'let ids = active.map { "\\($0.id):\\(String(format: "%.1f", $0.robustRSSI)" }.joined(separator: "|")',
    'let ids = active.map { "\\($0.id):\\(String(format: "%.1f", $0.robustRSSI))" }.joined(separator: "|")',
)
s = s.replace('strengthBand(score))', 'strengthBand(score: score))')
s = s.replace('strengthBand(score)))', 'strengthBand(score: score)))')

# Decode separated Offline Finding status information using the public protocol mapping.
s = s.replace(
'''struct OfflineFindingFrame {
    let publicKeyPayload: Data
    let rawManufacturerData: Data
''',
'''struct OfflineFindingFrame {
    let publicKeyPayload: Data
    let rawManufacturerData: Data
    let statusByte: UInt8
    let hintByte: UInt8

    var deviceType: String {
        switch (statusByte >> 4) & 0b00000011 {
        case 0b00: return "Apple Device"
        case 0b01: return "AirTag"
        case 0b10: return "3rd-Party Find My"
        case 0b11: return "AirPods"
        default: return "Unknown"
        }
    }

    var batteryLevel: String {
        switch (statusByte >> 6) & 0b00000011 {
        case 0b00: return "Full"
        case 0b01: return "Medium"
        case 0b10: return "Low"
        case 0b11: return "Very Low"
        default: return "Unknown"
        }
    }
''')
s = s.replace(
'''        self.publicKeyPayload = key
        self.rawManufacturerData = data
''',
'''        self.publicKeyPayload = key
        self.rawManufacturerData = data
        self.statusByte = data[4]
        self.hintByte = data[28]
''')

s = s.replace(
'''final class Candidate {
    let id: String
    var samples: [(time: TimeInterval, rssi: Double)] = []
''',
'''final class Candidate {
    let id: String
    var samples: [(time: TimeInterval, rssi: Double)] = []
    var deviceType: String
    var batteryLevel: String
    var statusByte: UInt8
    var hintByte: UInt8
''')
s = s.replace(
'''    init(id: String, now: TimeInterval) {
        self.id = id
        self.firstSeen = now
        self.lastSeen = now
    }

    func add(rssi: Double, now: TimeInterval) {
''',
'''    init(id: String, now: TimeInterval, frame: OfflineFindingFrame) {
        self.id = id
        self.firstSeen = now
        self.lastSeen = now
        self.deviceType = frame.deviceType
        self.batteryLevel = frame.batteryLevel
        self.statusByte = frame.statusByte
        self.hintByte = frame.hintByte
    }

    func add(rssi: Double, now: TimeInterval, frame: OfflineFindingFrame) {
        deviceType = frame.deviceType
        batteryLevel = frame.batteryLevel
        statusByte = frame.statusByte
        hintByte = frame.hintByte
''')

s = s.replace(
'''    guard f.publicKeyPayload.count == 22 else { return false }
''',
'''    guard f.publicKeyPayload.count == 22 else { return false }
    guard f.deviceType == "Apple Device" else { return false }
    guard f.batteryLevel == "Full" else { return false }
    guard f.statusByte == 0x00 else { return false }
''')

s = s.replace(
'''        let c = candidates[id] ?? Candidate(id: id, now: now)
        c.add(rssi: RSSI.doubleValue, now: now)
''',
'''        let c = candidates[id] ?? Candidate(id: id, now: now, frame: frame)
        c.add(rssi: RSSI.doubleValue, now: now, frame: frame)
''')

s = s.replace(
'writeCSV("timestamp,event,candidate,rssi,robust_rssi,score,trend_db,count,note\\n")',
'writeCSV("timestamp,event,candidate,rssi,robust_rssi,score,trend_db,count,device_type,battery,status_hex,hint_hex,note\\n")',
)
s = s.replace(
'''        writeCSV("\\(isoNow()),sample,\\(id),\\(RSSI.doubleValue),\\(String(format: "%.1f", c.robustRSSI)),\\(c.score),\\(String(format: "%.1f", c.trendDB)),\\(c.count),\\n")
''',
'''        writeCSV("\\(isoNow()),sample,\\(id),\\(RSSI.doubleValue),\\(String(format: "%.1f", c.robustRSSI)),\\(c.score),\\(String(format: "%.1f", c.trendDB)),\\(c.count),\\(c.deviceType),\\(c.batteryLevel),\\(String(format: "0x%02x", c.statusByte)),\\(String(format: "0x%02x", c.hintByte)),\\n")
''')
s = s.replace('writeCSV("\\(isoNow()),unpin,,,,,,,\\n")', 'writeCSV("\\(isoNow()),unpin,,,,,,,,,,,\\n")')
s = s.replace('writeCSV("\\(isoNow()),FIND_MY_MARK,,,,,,,\\(ids)\\n")', 'writeCSV("\\(isoNow()),FIND_MY_MARK,,,,,,,,,,,\\(ids)\\n")')
s = s.replace('writeCSV("\\(isoNow()),POSITION_P\\(snapshotCounter),,,,,,,\\(ids)\\n")', 'writeCSV("\\(isoNow()),POSITION_P\\(snapshotCounter),,,,,,,,,,,,\\(ids)\\n")')
s = s.replace('writeCSV("\\(isoNow()),pin,\\(selectedID!),,,,,,,\\n")', 'writeCSV("\\(isoNow()),pin,\\(selectedID!),,,,,,,,,,,\\n")')

s = s.replace(
'''                out.append("Peak raw RSSI this key-window: \\(String(format: "%.1f", c.peak)) dBm   Events: \\(c.count)")
''',
'''                out.append("Class: \\(c.deviceType)   Battery flag: \\(c.batteryLevel)   Status: \\(String(format: "0x%02x", c.statusByte))")
                out.append("Peak raw RSSI this key-window: \\(String(format: "%.1f", c.peak)) dBm   Events: \\(c.count)")
''')

old_discovery = '''        } else {
            out.append("\\(ANSI_BOLD)DISCOVERY MODE — no candidate pinned\\(ANSI_RESET)")
            if active.count == 1 && active[0].count >= 3 {
                out.append("Only one active Offline Finding candidate: \\(active[0].id). Press 1 to pin it.")
            } else if active.count > 1 {
                out.append("Multiple candidates present. Correlate with official Find My before pinning.")
            } else {
                out.append("No Offline Finding advertisement currently visible.")
            }
        }
'''
new_discovery = '''        } else {
            out.append("\\(ANSI_BOLD)DISCOVERY MODE — no candidate pinned\\(ANSI_RESET)")
            let appleClass = active.filter { $0.deviceType == "Apple Device" }
            if appleClass.count == 1 && appleClass[0].count >= 3 {
                out.append("Only one Apple-Device-class separated candidate is active: \\(appleClass[0].id). This narrows the field, but still correlate with official Find My before pinning.")
            } else if active.count == 1 && active[0].count >= 3 {
                out.append("Only one separated Offline Finding candidate: \\(active[0].id) (\\(active[0].deviceType)). Correlate before pinning.")
            } else if active.count > 1 {
                out.append("Multiple separated candidates present (Apple-Device class: \\(appleClass.count)). Correlate with official Find My before pinning.")
            } else {
                out.append("No separated Offline Finding advertisement currently visible.")
            }
        }
'''
s = s.replace(old_discovery, new_discovery)

s = s.replace(
'''        out.append("ACTIVE OFFLINE FINDING CANDIDATES")
        out.append(" #   window-id    robust    score   trend      age     events")
        out.append("---  ----------   -------   -----   ---------  ------  ------")
''',
'''        let appleClassCount = active.filter { $0.deviceType == "Apple Device" }.count
        out.append("ACTIVE SEPARATED-OFFLINE FINDING CANDIDATES   Apple-Device class: \\(appleClassCount)")
        out.append(" #   window-id    class       robust    score   trend      age    events")
        out.append("---  ----------   ----------  -------   -----   ---------  -----  ------")
''')
s = s.replace(
'''            let row = "\\(star)\\(idx)  \\(cid)   "
                + String(format: "%6.1f   %3d/100   %+6.1f dB   %4.1fs   %5d",
                         c.robustRSSI, c.score, c.trendDB, now - c.lastSeen, c.count)
''',
'''            let classShort: String
            switch c.deviceType {
            case "Apple Device": classShort = "APPLE"
            case "AirTag": classShort = "AIRTAG"
            case "AirPods": classShort = "AIRPODS"
            case "3rd-Party Find My": classShort = "3RD-PARTY"
            default: classShort = "UNKNOWN"
            }
            let cls = classShort.padding(toLength: 10, withPad: " ", startingAt: 0)
            let row = "\\(star)\\(idx)  \\(cid)   \\(cls)  "
                + String(format: "%6.1f   %3d/100   %+6.1f dB   %4.1fs  %5d",
                         c.robustRSSI, c.score, c.trendDB, now - c.lastSeen, c.count)
''')
s = s.replace(
'out.append("Mode: discovery only — NO connect / pair / write / Find My changes")',
'out.append("Mode: SEPARATED Offline Finding only (0x12/0x19) — NO connect / pair / write / Find My changes")',
)
s = s.replace(
'''        out.append(ANSI_DIM + "Window-ID derives from the visible 22-byte public-key payload fragment. Apple rotates Find My keys ~15 min; this is NOT a permanent device identifier." + ANSI_RESET)
''',
'''        out.append(ANSI_DIM + "0x19 is the separated-state Offline Finding payload. Device class/battery are decoded from its status byte; they are useful filters, not proof of identity." + ANSI_RESET)
        out.append(ANSI_DIM + "Window-ID derives from the visible 22-byte public-key payload fragment. Apple rotates Find My keys ~15 min; this is NOT a permanent device identifier." + ANSI_RESET)
''')

required = [
    'var deviceType: String',
    'Candidate(id: id, now: now, frame: frame)',
    'Apple-Device class:',
    'SEPARATED Offline Finding only',
    'status_hex,hint_hex',
]
missing = [x for x in required if x not in s]
if missing:
    raise SystemExit(f'v3.1 patch incomplete: {missing}')

p.write_text(s)
print('V31_PATCH_APPLIED')
