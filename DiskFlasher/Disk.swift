import Foundation

struct Disk: Identifiable, Hashable {
    /// BSD identifier such as "disk4".
    let id: String
    let name: String
    let size: Int64
    let busProtocol: String

    var devicePath: String { "/dev/\(id)" }
    var rawDevicePath: String { "/dev/r\(id)" }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var label: String {
        "\(name) (\(formattedSize), \(busProtocol)) \(devicePath)"
    }
}

enum DiskService {
    private static let diskutil = "/usr/sbin/diskutil"

    /// Whole external physical disks, as reported by `diskutil`. Internal disks are never listed.
    static func externalDisks() async -> [Disk] {
        let result = await Shell.run(diskutil, ["list", "-plist", "external", "physical"])
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any],
              let identifiers = plist["WholeDisks"] as? [String] else {
            return []
        }
        var disks: [Disk] = []
        for identifier in identifiers {
            if let disk = await info(for: identifier) {
                disks.append(disk)
            }
        }
        return disks
    }

    /// Looks up one disk, returning nil unless it is a whole, writable, non-internal disk.
    static func info(for identifier: String) async -> Disk? {
        guard identifier.wholeMatch(of: /disk[0-9]+/) != nil else { return nil }
        let result = await Shell.run(diskutil, ["info", "-plist", identifier])
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any],
              plist["WholeDisk"] as? Bool == true,
              plist["Internal"] as? Bool == false,
              plist["WritableMedia"] as? Bool != false else {
            return nil
        }
        let mediaName = (plist["MediaName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return Disk(
            id: identifier,
            name: mediaName.isEmpty ? "Untitled disk" : mediaName,
            size: (plist["TotalSize"] as? NSNumber)?.int64Value ?? 0,
            busProtocol: plist["BusProtocol"] as? String ?? "Unknown"
        )
    }
}
