import Foundation

/// System facts that gate Force Eject (S2) and feed remedies. Each call spawns a process (~10-100 ms):
/// keep off the main thread and the hot path; never called by the scanner.
public enum SystemState {
    public struct TimeMachineDestination: Sendable, Hashable {
        public let id: String
        public let name: String?
        public let kind: String?           // "Local" / "Network"
        public let mountPoint: String?
        /// Volume UUID of the mounted destination (from its mount point), nil if not mounted.
        public let volumeUUID: String?
    }

    /// What `tmutil` says. Only produced when tmutil answered and its output parsed.
    public struct TimeMachineState: Sendable, Hashable {
        /// `tmutil status` -> `Running = 1;`
        public let backupRunning: Bool
        /// `tmutil destinationinfo -X`, read only while a backup runs. Nil when not read, or when that call failed
        /// (callers treat "running, destinations unknown" as "may be this disk", fail closed).
        public let destinations: [TimeMachineDestination]?

        public init(backupRunning: Bool, destinations: [TimeMachineDestination]?) {
            self.backupRunning = backupRunning; self.destinations = destinations
        }
    }

    /// Time Machine's state, or nil when it is unknown: tmutil missing, timed out, exited non-zero, or printed
    /// something that does not parse. S2: unknown keeps Force Eject disabled (fail closed).
    public static func timeMachineState(timeout: TimeInterval = 5) -> TimeMachineState? {
        guard let status = run("/usr/bin/tmutil", ["status"], timeout: timeout),
              let running = parseTimeMachineRunning(status) else { return nil }
        guard running else { return TimeMachineState(backupRunning: false, destinations: nil) }
        let dests = run("/usr/bin/tmutil", ["destinationinfo", "-X"], timeout: timeout).flatMap { parseDestinations(Data($0.utf8)) }
        return TimeMachineState(backupRunning: true, destinations: dests)
    }

    /// `Running = 1;` -> true, `Running = 0;` -> false, no parsable `Running` line -> nil.
    static func parseTimeMachineRunning(_ status: String) -> Bool? {
        for line in status.split(separator: "\n") {
            let t = line.filter { !$0.isWhitespace }
            guard t.hasPrefix("Running=") else { continue }
            switch t.dropFirst("Running=".count).prefix(while: \.isNumber) {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// `tmutil destinationinfo -X` plist. An empty dict (no destinations configured) is `[]`; unparsable is nil.
    static func parseDestinations(_ plist: Data) -> [TimeMachineDestination]? {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { return nil }
        guard let raw = root["Destinations"] else { return [] }
        guard let list = raw as? [[String: Any]] else { return nil }
        return list.compactMap { d in
            guard let id = d["ID"] as? String else { return nil }
            let mount = d["MountPoint"] as? String
            let uuid = mount.flatMap { try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString }
            return TimeMachineDestination(id: id, name: d["Name"] as? String, kind: d["Kind"] as? String, mountPoint: mount, volumeUUID: uuid)
        }
    }

    /// `mdutil -s <volume>`: true "Indexing enabled.", false "Indexing disabled."/"…and disabled", nil unknown.
    public static func spotlightIndexingEnabled(volumePath: String) -> Bool? {
        guard let out = run("/usr/bin/mdutil", ["-s", volumePath]) else { return nil }
        return parseSpotlight(out)
    }

    static func parseSpotlight(_ out: String) -> Bool? {
        let s = out.lowercased()
        if s.contains("indexing disabled") || s.contains("indexing and searching disabled") { return false }
        if s.contains("indexing enabled") { return true }
        return nil
    }

    /// Run a tool with a timeout; stdout+stderr as text. Nil on launch failure, timeout or a non-zero exit status.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { [p] in if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
