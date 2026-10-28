import Foundation

/// devicectl stages read-only fixtures in Caches. Copy them into a unique,
/// app-owned temporary directory so core saves and scratch files are writable.
/// The user's console folders and Documents are never used on the phone.
enum PhysicalFixturePaths {
    private static let physicalRoot:URL = {
        let fm=FileManager.default
        let staged=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("VETA-Physical-144",isDirectory:true)
        let writable=fm.temporaryDirectory.appendingPathComponent("VETA-Physical-144-"+UUID().uuidString,isDirectory:true)
        do {try fm.copyItem(at:staged,to:writable)}
        catch {preconditionFailure("Cannot prepare writable physical test fixtures: \(error)")}
        return writable
    }()
    static var root:URL {
        if ProcessInfo.processInfo.environment["VETA_PHYSICAL_FIXTURES"] == "144" {return physicalRoot}
        return FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    }
}
