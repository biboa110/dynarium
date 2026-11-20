// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The device's storage as the application reads it.
public enum HostStorage {
    /// Free space on the volume of the application's container, as the system
    /// states it for what the user cares about (purgeable space counts).
    ///
    /// The "important usage" figure comes from a system daemon and can come
    /// back missing or zero while the device is under heavy memory pressure
    /// (a booting guest on a 3 GiB iPhone), which must never read as "the disk
    /// is full". The plain volume figure and then statfs stand in for it, and
    /// zero is returned only when every source failed: callers treat zero as
    /// unknown rather than as an empty disk.
    public static func freeBytes(on directory: URL = URL(fileURLWithPath: NSHomeDirectory())) -> UInt64 {
        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let plain = values.volumeAvailableCapacity, plain > 0 {
            return UInt64(plain)
        }
        var stats = statfs()
        if statfs(directory.path, &stats) == 0 {
            let bytes = UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
            if bytes > 0 { return bytes }
        }
        return 0
    }
}
