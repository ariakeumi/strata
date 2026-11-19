import Foundation
import NetFS.NetFSPlugin
import StrataSupport

nonisolated struct SMBLogin: Sendable {
    let user: String
    let password: String
}

nonisolated enum SMBShareListingError: Error {
    case unavailable
    case status(Int32)

    var requiresLogin: Bool {
        if case .status(let code) = self { return [EAUTH, EPERM, EACCES].contains(code) }
        return false
    }

    var problem: ServerConnection.Problem? {
        switch self {
        case .unavailable: ServerConnection.problem(ENOTSUP)
        case .status(let code): ServerConnection.problem(code)
        }
    }
}

nonisolated enum SMBShareListing {
    static func read(_ url: URL, password: String?, guest: Bool) async throws -> [String] {
        guard let result = await OwnThread.runUnlessCancelled({ list(url, password: password, guest: guest) }) else {
            throw CancellationError()
        }
        return try result.get()
    }

    private static func list(_ url: URL, password: String?, guest: Bool) -> Result<[String], SMBShareListingError> {
        // NetFSMountURLAsync presents the system share picker for a server URL. The SMB plug-in exposes
        // opening a session and enumerating it separately through the SDK's NetFS plug-in interface.
        let path = URL(filePath: "/System/Library/Filesystems/NetFSPlugins/smb.bundle", directoryHint: .isDirectory)
        guard var address = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let type = CFUUIDCreateFromString(nil, "02FE7D14-4E91-481E-946C-CE233C798CC0" as CFString),
              let iid = CFUUIDCreateFromString(nil, "8F34B6C4-F2E4-4ECD-8625-E5665811DE37" as CFString),
              let plugin = CFPlugInCreate(nil, path as CFURL),
              let factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(type, plugin), CFArrayGetCount(factories) > 0,
              let first = CFArrayGetValueAtIndex(factories, 0),
              let instance = CFPlugInInstanceCreate(nil, Unmanaged<CFUUID>.fromOpaque(first).takeUnretainedValue(), type)
        else { return .failure(.unavailable) }
        defer { _ = NetFSInterface_Release(instance) }

        var target: UnsafeMutableRawPointer?
        guard NetFSQueryInterface(instance, CFUUIDGetUUIDBytes(iid), &target) == 0, let target else {
            return .failure(.unavailable)
        }
        defer { _ = NetFSInterface_Release(target) }
        guard let table = target.assumingMemoryBound(to: NetFSInterface.self).pointee._interface else {
            return .failure(.unavailable)
        }
        let api = table.assumingMemoryBound(to: NetFSMountInterface_V1.self).pointee

        var session: UnsafeMutableRawPointer?
        let created = api.CreateSessionRef(&session)
        guard created == 0 else { return .failure(.status(created)) }
        guard let session else { return .failure(.unavailable) }
        defer { _ = api.CloseSession(session) }

        address.password = password
        guard let server = address.url else { return .failure(.unavailable) }
        let options: [String: Any] = [kNAUIOptionKey as String: kNAUIOptionNoUI, kNetFSUseGuestKey as String: guest]
        var info: Unmanaged<CFDictionary>?
        let opened = api.OpenSession(server as CFURL, session, options as CFDictionary, &info)
        _ = info?.takeRetainedValue()
        guard opened == 0 else { return .failure(.status(opened)) }

        var shares: Unmanaged<CFDictionary>?
        let enumerated = api.EnumerateShares(session, [:] as CFDictionary, &shares)
        let records = shares?.takeRetainedValue()
        guard enumerated == 0 else { return .failure(.status(enumerated)) }
        return .success(diskShares((records as NSDictionary?) as? [String: [String: Any]] ?? [:]))
    }

    static func diskShares(_ records: [String: [String: Any]]) -> [String] {
        records.compactMap { name, info in
            guard info["NetShareTypeStr"] as? String == "Disk" else { return nil }
            return info[kNetFSDisplayNameKey as String] as? String ?? name
        }
    }
}
