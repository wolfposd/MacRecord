import AppKit
import CoreAudio
import Darwin

/// One user-visible application, grouping all of its audio-capable helper processes.
struct AudioApp: Identifiable, Hashable {
    let id: String               // owning .app path, or "pid-N" for bare processes
    let name: String
    let iconPath: String?
    let bundleID: String?
    var isApple: Bool { bundleID?.hasPrefix("com.apple.") == true }
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
}

enum ProcessCatalog {
    static func snapshot() -> [AudioApp] {
        let objects = (try? AudioObjectID.systemObject.getArray(
            kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self)) ?? []
        let me = getpid()
        var groups: [String: AudioApp] = [:]

        for object in objects {
            guard let pid = try? object.get(kAudioProcessPropertyPID, as: pid_t.self), pid != me else { continue }
            let playing = ((try? object.get(kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0) != 0

            let executable = executablePath(pid: pid)
            let appURL = executable.flatMap(outermostAppURL)
            let key = appURL?.path ?? "pid-\(pid)"

            if var existing = groups[key] {
                existing.processObjects.append(object)
                existing.isPlaying = existing.isPlaying || playing
                groups[key] = existing
            } else {
                let fallbackName = [
                    object.getString(kAudioProcessPropertyBundleID),
                    executable.map { ($0 as NSString).lastPathComponent },
                    processName(pid: pid),               // works for root daemons whose path we can't read
                ].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? "Process \(pid)"
                groups[key] = AudioApp(
                    id: key,
                    name: appURL.map(displayName) ?? fallbackName,
                    iconPath: appURL?.path,
                    bundleID: appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
                        ?? object.getString(kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 },
                    processObjects: [object],
                    isPlaying: playing)
            }
        }
        // Third-party apps first, Apple's own (com.apple.*) at the bottom; alphabetical within each group.
        return groups.values.sorted {
            if $0.isApple != $1.isApple { return !$0.isApple }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if length > 0 { return String(cString: buffer) }
        return NSRunningApplication(processIdentifier: pid)?.executableURL?.path
    }

    /// `/A.app/Contents/Frameworks/B.app/…/helper` -> `/A.app` (the app the user actually launched).
    private static func outermostAppURL(_ path: String) -> URL? {
        var components: [String] = []
        for component in (path as NSString).pathComponents {
            components.append(component)
            if component.hasSuffix(".app") { return URL(fileURLWithPath: NSString.path(withComponents: components)) }
        }
        return nil
    }

    private static func displayName(_ url: URL) -> String {
        let info = Bundle(url: url)?.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}
