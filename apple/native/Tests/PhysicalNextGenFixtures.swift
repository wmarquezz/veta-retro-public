#if VETA_JIT_DEVELOPMENT
import XCTest
@testable import VetaJITLab

/// Explicitly opted-in physical fixture staging. Never selected by a regular
/// test run, and never replaces an existing game or system installation.
@MainActor final class PhysicalNextGenFixtures:XCTestCase {
    func testRemovePhysicalFixtures() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_CLEANUP_PHYSICAL_FIXTURES"] == "144")
        let fm=FileManager.default
        let record=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("VETA-NextGen-144-added.json")
        let ids=try JSONDecoder().decode([String].self,from:Data(contentsOf:record))
        let library=Library()
        for id in ids {
            guard let game=library.games.first(where:{$0.id==id}) else{continue}
            XCTAssertTrue(game.name.hasPrefix("VETA QA "),"Only fixtures created by this session may be removed")
            guard game.name.hasPrefix("VETA QA ") else{continue}
            try library.remove(game)
        }
        XCTAssertFalse(library.games.contains{ids.contains($0.id)})
        XCTAssertNil(library.error)
    }
    func testPreparePhysicalFixtures() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_PREPARE_PHYSICAL_FIXTURES"] == "144")
        let fm=FileManager.default
        let source=fm.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("VETA-NextGen-144")
        let library=Library()
        let record=source.deletingLastPathComponent().appendingPathComponent("VETA-NextGen-144-added.json")
        // Preserve ownership across interrupted/repeated preparation. Without
        // this, a second run overwrites the record with [] and leaks fixtures.
        var added=try fm.fileExists(atPath:record.path) ? JSONDecoder().decode([String].self,from:Data(contentsOf:record)) : []
        for (console,file,name) in [(GameConsole.xbox,"Pong-audio-test.iso","VETA QA Xbox"),(.xbox360,"veta_av.xex","VETA QA Xbox 360")] {
            let original=Set(library.games.map(\.id))
            var game=try library.importExperimental(source.appendingPathComponent(file),console:console)
            if !original.contains(game.id) {
                game.name=name;library.update(game)
                if !added.contains(game.id) {added.append(game.id)}
                try JSONEncoder().encode(added).write(to:record,options:.atomic)
            }
        }
        let system=library.root.appendingPathComponent("NativeEngines/xbox/System/xbox")
        if !fm.fileExists(atPath:system.path) {try XboxSystemFiles.install(from:source.appendingPathComponent("xbox"),to:system)}
        try JSONEncoder().encode(added).write(to:record,options:.atomic)
        XCTAssertNil(library.error)
        XCTAssertEqual(library.games.filter{$0.name.hasPrefix("VETA QA ")}.count,2)
    }
}
#endif
