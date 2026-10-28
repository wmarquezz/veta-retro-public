#if VETA_JIT_DEVELOPMENT
import XCTest
import NetworkExtension
import CryptoKit
@testable import VetaJITLab

/// Opt-in migration of the separately backed-up primary library. Uses the
/// normal validated backup importer; never replaces an app container or game.
@MainActor final class PhysicalConsolidationFixtures:XCTestCase {
    /// Read-only proof for the physical offline matrix. Never saves or starts a tunnel.
    func test162OwnVPNRemainsDisconnected() async {
        let read = expectation(description: "Read own VPN status")
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            XCTAssertNil(error)
            let provider = (Bundle.main.bundleIdentifier ?? "") + ".localtunnel"
            let own = (managers ?? []).filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == provider
            }
            for manager in own {
                XCTAssertTrue([NEVPNStatus.disconnected, .invalid].contains(manager.connection.status),
                              "Offline validation requires the own VPN to remain stopped")
            }
            print("VETA162_VPN ownProfiles=\(own.count) statuses=\(own.map{$0.connection.status.rawValue})")
            read.fulfill()
        }
        await fulfillment(of: [read], timeout: 15)
    }
    func test156EveryLibraryGameHasDecodableOfflineArtwork()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_ARTWORK_156"] == "1")
        let library=Library()
        XCTAssertEqual(library.games.count,36)
        for game in library.games {
            let data=try Data(contentsOf:library.file(game,"cover.vcover"))
            let record=try CoverRecord.decode(data)
            XCTAssertFalse(record.image.isEmpty,game.name)
            if !record.manual {XCTAssertEqual(record.source?.host,"raw.githubusercontent.com",game.name)}
        }
    }
    struct RetirementPlan:Decodable {
        let games:[Game]
        let roots:[String]
        let retiredFiles:[String:String]
        let keptFiles:[String:String]
    }
    /// Explicit, one-off user-authorized removal. All files to be removed must
    /// match the complete external backup before the first destructive action.
    func test161RetireBackedUpConsoles()async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_RETIRE_161"] == "1")
        guard Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String == "161" else {throw VetaError.message("Wrong product")}
        let fm=FileManager.default,home=URL(fileURLWithPath:NSHomeDirectory())
        let plan=try JSONDecoder().decode(RetirementPlan.self,from:Data(contentsOf:home.appendingPathComponent("Library/Caches/VETA-Retirement-161.json")))
        let retired:Set<GameConsole>=[.xbox,.ps3,.xbox360]
        let removed=plan.games.filter{retired.contains($0.console)}
        let kept=plan.games.filter{!retired.contains($0.console)}
        var allowed:Set<String>=["Library/Caches/VETA-NextGen-144","Library/Caches/VETA-NextGen-144-added.json","Library/Caches/VETA-Xbox151","Library/Application Support/VetaNative/PS3PendingDeletes"]
        for name in ["Xbox","PlayStation 3","Xbox 360"] {
            allowed.insert("Documents/"+name);allowed.insert("Documents/Archivos conservados/"+name)
        }
        for name in ["xbox","ps3","xbox360"] {allowed.insert("Library/Application Support/VetaNative/NativeEngines/"+name)}
        for game in removed {
            guard WebEngineArchive.isDigest(game.id) else{throw VetaError.message("Invalid retired game")}
            allowed.insert("Library/Application Support/VetaNative/"+game.id)
        }
        for path in plan.roots where path.hasPrefix("Library/Caches/VetaTV158RenderQA-offline160-xbox-") && path.split(separator:"/").count==3 {allowed.insert(path)}
        guard !removed.isEmpty,Set(plan.roots).isSubset(of:allowed),Set(plan.roots).count==plan.roots.count else{throw VetaError.message("Invalid retirement scope")}
        func inside(_ path:String)->Bool {plan.roots.contains{path==$0 || path.hasPrefix($0+"/")}}
        guard plan.retiredFiles.keys.allSatisfy(inside),!plan.keptFiles.keys.contains(where:inside) else{throw VetaError.message("Overlapping retirement scope")}
        let before=Library(root:home.appendingPathComponent("Library/Application Support/VetaNative"))
        guard before.games==plan.games else{throw VetaError.message("Library changed after backup")}
        // The normal Documents migration may have archived Xbox on first launch.
        // Canonicalize that exact relocation, never silently accept another file.
        let actual=try await Task.detached(priority:.utility) { () throws -> [String:String] in
            var actual:[String:String]=[:]
            for path in plan.roots {
                let root=home.appendingPathComponent(path)
                guard fm.fileExists(atPath:root.path) else{continue}
                let info=try root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard info.isSymbolicLink != true else{throw VetaError.message("Unexpected link")}
                var urls=[root]
                if info.isDirectory==true {
                    var walkError:Error?
                    guard let walk=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],errorHandler:{_,error in walkError=error;return false}) else{throw VetaError.message("Cannot enumerate retired files")}
                    urls=walk.compactMap{$0 as? URL}
                    if let walkError {throw walkError}
                }
                for url in urls {
                    let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                    guard info.isSymbolicLink != true else{throw VetaError.message("Unexpected link")}
                    guard info.isRegularFile==true else{continue}
                    let canonicalHome=home.resolvingSymlinksInPath().standardizedFileURL.path
                    let canonicalFile=url.resolvingSymlinksInPath().standardizedFileURL.path
                    guard canonicalFile.hasPrefix(canonicalHome+"/") else{throw VetaError.message("File outside app container")}
                    var relative=String(canonicalFile.dropFirst(canonicalHome.count+1))
                    for name in ["Xbox","PlayStation 3","Xbox 360"] {
                        relative=relative.replacingOccurrences(of:"Documents/Archivos conservados/"+name+"/",with:"Documents/"+name+"/",options:.anchored)
                    }
                    guard actual[relative]==nil else{throw VetaError.message("Ambiguous retired file")}
                    actual[relative]=try Self.retirementHash(url)
                }
            }
            return actual
        }.value
        if actual != plan.retiredFiles {
            let delta:[String:Any]=["actual":actual,"missing":plan.retiredFiles.keys.filter{actual[$0]==nil}.sorted(),"unexpected":actual.keys.filter{plan.retiredFiles[$0]==nil}.sorted(),"changed":actual.keys.filter{plan.retiredFiles[$0] != nil && plan.retiredFiles[$0] != actual[$0]}.sorted()]
            try JSONSerialization.data(withJSONObject:delta,options:.sortedKeys).write(to:home.appendingPathComponent("Library/Caches/VETA-Retirement-161-mismatch.json"),options:.atomic)
            print("VETA161_MISMATCH actual=\(actual.count) expected=\(plan.retiredFiles.count); diagnostic saved")
            throw VetaError.message("Retired data differs from verified backup; nothing removed")
        }
        print("VETA161_BACKUP_READBACK files=\(actual.count)")
        for game in removed {try before.remove(game)}
        for path in plan.roots {
            let url=home.appendingPathComponent(path)
            if fm.fileExists(atPath:url.path) {try fm.removeItem(at:url)}
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where ["native.xbox.","native.ps3.","native.xbox360."].contains(where:key.hasPrefix) {UserDefaults.standard.removeObject(forKey:key)}
        guard before.games==kept else{throw VetaError.message("Unexpected library after removal")}
        guard before.consoles==Set(GameConsole.allCases) else{throw VetaError.message("Unexpected console selection")}
        for path in plan.roots {XCTAssertFalse(fm.fileExists(atPath:home.appendingPathComponent(path).path),path)}
        let keptHashes=try await Task.detached(priority:.utility) { () throws -> [String:String] in
            var result:[String:String]=[:]
            for path in plan.keptFiles.keys {
                guard !path.hasPrefix("/"),!path.split(separator:"/").contains(".."),path.hasPrefix("Documents/") || path.hasPrefix("Library/Application Support/VetaNative/") else{throw VetaError.message("Invalid preservation path")}
                result[path]=try Self.retirementHash(home.appendingPathComponent(path))
            }
            return result
        }.value
        guard keptHashes==plan.keptFiles else{throw VetaError.message("Preservation mismatch")}
        let receipt:[String:Any]=["version":161,"games":kept.count,"consoles":before.consoles.count,"retiredFilesVerifiedBeforeRemoval":actual.count,"keptFilesVerifiedAfterRemoval":keptHashes.count,"removedGameIDs":removed.map(\.id),"removedRoots":plan.roots]
        try JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys).write(to:home.appendingPathComponent("Library/Caches/VETA-Retirement-161-result.json"),options:.atomic)
        print("VETA161_RETIREMENT games=\(kept.count) consoles=\(before.consoles.count) removed=\(actual.count) kept=\(keptHashes.count)")
    }
    func test161FinishRetiredCacheCleanup()async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_RETIRE_161"] == "2")
        let fm=FileManager.default,home=URL(fileURLWithPath:NSHomeDirectory()).resolvingSymlinksInPath()
        let plan=try JSONDecoder().decode(RetirementPlan.self,from:Data(contentsOf:home.appendingPathComponent("Library/Caches/VETA-Retirement-161.json")))
        let kept=plan.games.filter{![GameConsole.xbox,.ps3,.xbox360].contains($0.console)}
        guard Library().games==kept,kept.count==35 else{throw VetaError.message("Unexpected library during cleanup")}
        let roots=plan.roots.filter{$0.hasPrefix("Library/Caches/VetaTV158RenderQA-offline160-xbox-") && $0.split(separator:"/").count==3}
        var directories:[URL]=[],verified=0
        for path in roots {
            let root=home.appendingPathComponent(path)
            guard fm.fileExists(atPath:root.path) else{continue}
            print("VETA161_CACHE_ATTRIBUTES \(path) \(try fm.attributesOfItem(atPath:root.path))")
            let info=try root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard info.isDirectory==true,info.isSymbolicLink != true else{throw VetaError.message("Invalid retired cache root")}
            directories.append(root)
            var walkError:Error?
            guard let walk=fm.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],errorHandler:{_,error in walkError=error;return false}) else{throw VetaError.message("Cannot enumerate cache")}
            for case let url as URL in walk {
                let info=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard info.isSymbolicLink != true else{throw VetaError.message("Unexpected link")}
                if info.isDirectory==true {directories.append(url);continue}
                let canonical=url.resolvingSymlinksInPath().path
                guard canonical.hasPrefix(home.path+"/") else{throw VetaError.message("Invalid cache path")}
                let path=String(canonical.dropFirst(home.path.count+1))
                guard let expected=plan.retiredFiles[path],try Self.retirementHash(url)==expected else{throw VetaError.message("Cache differs from backup")}
                verified += 1
            }
            if let walkError {throw walkError}
        }
        // Repair writable attributes only on these verified, retired cache trees.
        // Keep all other app directories and user content unchanged.
        for directory in directories {
            print("VETA161_CACHE_DIRECTORY \(directory.lastPathComponent) \(try fm.attributesOfItem(atPath:directory.path))")
            try fm.setAttributes([.posixPermissions:0o700,.immutable:false,.appendOnly:false],ofItemAtPath:directory.path)
        }
        for path in roots {
            let url=home.appendingPathComponent(path)
            if fm.fileExists(atPath:url.path) {try fm.removeItem(at:url)}
        }
        for path in plan.roots {XCTAssertFalse(fm.fileExists(atPath:home.appendingPathComponent(path).path),path)}
        for key in UserDefaults.standard.dictionaryRepresentation().keys where ["native.xbox.","native.ps3.","native.xbox360."].contains(where:key.hasPrefix) {UserDefaults.standard.removeObject(forKey:key)}
        print("VETA161_CACHE_CLEANUP verified=\(verified) rootsAbsent=\(plan.roots.count)")
    }
    nonisolated private static func retirementHash(_ url:URL)throws->String {
        let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard info.isRegularFile==true,info.isSymbolicLink != true else{throw VetaError.message("Invalid audit file")}
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()};var hash=SHA256()
        while try autoreleasepool(invoking:{ () throws -> Bool in
            guard let data=try file.read(upToCount:1024*1024),!data.isEmpty else{return false}
            hash.update(data:data);return true
        }) {}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    struct FinalPlan:Decodable {let games:[Game];let ids:[String];let files:[String:String]}
    func test152VerifyPreservedLibrary()async throws {
        try XCTSkipUnless(["1","157","158","161"].contains(ProcessInfo.processInfo.environment["VETA_FINALIZE_152"] ?? ""))
        let fm=FileManager.default,library=Library(),home=URL(fileURLWithPath:NSHomeDirectory())
        let version=ProcessInfo.processInfo.environment["VETA_FINALIZE_152"] ?? "1"
        let manifest=version == "1" ? "VETA-Final-152.json":"VETA-Final-"+version+".json"
        let plan=try JSONDecoder().decode(FinalPlan.self,from:Data(contentsOf:home.appendingPathComponent("Library/Caches/"+manifest)))
        XCTAssertEqual(Set(library.games.map(\.id)),Set(plan.ids))
        for var expected in plan.games {
            let actual=try XCTUnwrap(library.games.first{$0.id==expected.id})
            expected.lastPlayed=actual.lastPlayed
            XCTAssertEqual(actual,expected,"Only the playback timestamp may change during tests")
        }
        // Full-library TV checks include multi-GB disks. Keep hashing off the
        // UI thread and drain Foundation read buffers after every chunk.
        let files=plan.files
        let actualHashes=try await Task.detached(priority:.utility) { () throws -> [String:String] in
            var result:[String:String]=[:]
            for path in files.keys.sorted() {
                guard !path.hasPrefix("/"),!path.split(separator:"/").contains(".."),path.hasPrefix("Documents/") || path.hasPrefix("Library/Application Support/VetaNative/") else {throw VetaError.message("Invalid preservation audit path")}
                let url=home.appendingPathComponent(path)
                let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                guard info.isRegularFile==true,info.isSymbolicLink != true else {throw VetaError.message("Invalid preservation audit file")}
                let file=try FileHandle(forReadingFrom:url)
                defer {try? file.close()}
                var hash=SHA256()
                while try autoreleasepool(invoking:{ () throws -> Bool in
                    guard let data=try file.read(upToCount:1024*1024),!data.isEmpty else{return false}
                    hash.update(data:data);return true
                }) {}
                result[path]=hash.finalize().map{String(format:"%02x",$0)}.joined()
            }
            return result
        }.value
        XCTAssertEqual(actualHashes.count,files.count)
        for (path,digest) in files {XCTAssertEqual(actualHashes[path],digest,path)}
        XCTAssertFalse(library.consoles.contains(.ps3));XCTAssertFalse(library.consoles.contains(.xbox360))
        if version == "161" {XCTAssertFalse(library.consoles.contains(.xbox));XCTAssertFalse(library.games.contains{[.xbox,.ps3,.xbox360].contains($0.console)})}
        print("VETA152_PRESERVATION games=\(library.games.count) files=\(plan.files.count)")
        XCTAssertTrue(fm.fileExists(atPath:library.root.appendingPathComponent("retail-rotation-147.json").path))
    }
    func test152RemoveDiagnosticHUD()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_FINALIZE_152"] == "1")
        let before=Library().games
        UserDefaults.standard.removeObject(forKey:"MetalForceHudEnabled")
        XCTAssertNil(UserDefaults.standard.object(forKey:"MetalForceHudEnabled"))
        XCTAssertEqual(Library().games,before)
    }
    struct Plan:Decodable {let games:[Game];let files:[String:String];let backupSHA256:String}
    func testPrepareMissingPrimaryDocuments148()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_MERGE_PRIMARY"] == "148")
        let fm=FileManager.default,home=URL(fileURLWithPath:NSHomeDirectory())
        let cache=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0]
        let files=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:cache.appendingPathComponent("VETA-Primary-Documents-148.json")))
        for (path,digest) in files {
            let parts=path.split(separator:"/").map(String.init)
            guard parts.count>=3,parts[0]=="Documents",GameFiles.consoles.contains(parts[1]),parts.allSatisfy(DiscFiles.safeName) else {throw VetaError.message("Invalid document path")}
            let target=home.appendingPathComponent(path)
            if fm.fileExists(atPath:target.path) {
                guard sha256(try Data(contentsOf:target))==digest else{throw VetaError.message("Conflicting document preserved")}
            }
            try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
    }
    func testAuditPrimaryDocuments148()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_MERGE_PRIMARY"] == "148")
        let home=URL(fileURLWithPath:NSHomeDirectory())
        let cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
        let files=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:cache.appendingPathComponent("VETA-All-Primary-Documents-148.json")))
        for (path,digest) in files {
            guard path.hasPrefix("Documents/"),!path.split(separator:"/").contains("..") else {throw VetaError.message("Invalid document audit path")}
            XCTAssertEqual(sha256(try Data(contentsOf:home.appendingPathComponent(path),options:.mappedIfSafe)),digest,path)
        }
        print("VETA148_PRIMARY_DOCUMENTS files=\(files.count)")
    }
    func testMergePrimaryLibrary148()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_MERGE_PRIMARY"] == "148")
        let fm=FileManager.default,library=Library()
        let cache=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0]
        let plan=try JSONDecoder().decode(Plan.self,from:Data(contentsOf:cache.appendingPathComponent("VETA-Primary-148.json")))
        let backup=cache.appendingPathComponent("VETA-Primary-148.vetaretro")
        XCTAssertEqual(sha256(try Data(contentsOf:backup)),plan.backupSHA256)
        guard sha256(try Data(contentsOf:backup))==plan.backupSHA256 else{return}
        let originals=library.games
        func hashes(_ games:[Game])throws->[String:String] {
            var result:[String:String]=[:]
            for game in games {
                let folder=library.directory(game.id)
                guard let walker=fm.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else {throw VetaError.message("Missing game folder")}
                for case let url as URL in walker {
                    let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                    guard info.isSymbolicLink != true else{throw VetaError.message("Unexpected link")}
                    if info.isRegularFile == true {
                        result[String(url.path.dropFirst(library.root.path.count+1))]=sha256(try Data(contentsOf:url,options:.mappedIfSafe))
                    }
                }
            }
            return result
        }
        let before=try hashes(originals)
        try library.importURLs([backup],console:nil)
        XCTAssertEqual(library.games.filter{originals.map(\.id).contains($0.id)},originals)
        XCTAssertEqual(try hashes(originals),before,"Existing ROMs, states and artwork must remain byte-identical")
        for game in plan.games {XCTAssertEqual(library.games.first{$0.id==game.id},game)}
        for (path,digest) in plan.files {
            let components=path.split(separator:"/")
            guard components.count==2,plan.games.contains(where:{$0.id==components[0]}),DiscFiles.safeName(String(components[1])) else {throw VetaError.message("Invalid primary-library audit path")}
            XCTAssertEqual(sha256(try Data(contentsOf:library.root.appendingPathComponent(path))),digest,path)
        }
        let preferences=try Data(contentsOf:cache.appendingPathComponent("VETA-Primary-148.plist"))
        let values=try XCTUnwrap(PropertyListSerialization.propertyList(from:preferences,format:nil) as? [String:Any])
        // User's visual choices win; don't replace laboratory diagnostics/history.
        for key in ["native.libraryList","native.skin","native.threeDS.skin.portrait"] {
            if let value=values[key] {UserDefaults.standard.set(value,forKey:key)}
        }
        UserDefaults.standard.removeObject(forKey:"MetalForceHudEnabled")
        print("VETA148_PRIMARY_MERGE originals=\(originals.count) total=\(library.games.count) originalFiles=\(before.count) importedFiles=\(plan.files.count)")
    }
}
#endif
