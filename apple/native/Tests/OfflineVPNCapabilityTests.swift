#if VETA_JIT_DEVELOPMENT
import XCTest
import NetworkExtension
@testable import VetaJITLab

@MainActor final class OfflineVPNCapabilityTests:XCTestCase {
    func test160ColdOnDemandProfile()async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_OFFLINE160_VPN"] == "ondemand")
        let managers=try await NETunnelProviderManager.loadAllFromPreferences()
        let own=managers.filter{($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == EmbeddedVPNBackend.providerID}
        XCTAssertEqual(own.count,1)
        let manager=try XCTUnwrap(own.first)
        XCTAssertEqual(manager.connection.status,.disconnected,"Must begin with VPN stopped")
        let original=manager.protocolConfiguration, rules=manager.onDemandRules
        let demand=manager.isOnDemandEnabled, enabled=manager.isEnabled
        let backend=EmbeddedVPNBackend()
        var success=false,operationError:Error?
        do {
            try await backend.prepare();try backend.start()
            let end=Date().addingTimeInterval(20)
            while Date()<end {
                if backend.state == .connected {success=true;break}
                try await Task.sleep(nanoseconds:250_000_000)
            }
            let current=try await NETunnelProviderManager.loadAllFromPreferences()
            let target=current.first{($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == EmbeddedVPNBackend.providerID}
            if let target {
                let error:NSError?=await withCheckedContinuation{c in target.connection.fetchLastDisconnectError{c.resume(returning:$0 as NSError?)}}
                print("VETA160_COLD_VPN connected=\(success) status=\(target.connection.status.rawValue) errorDomain=\(error?.domain ?? "none") errorCode=\(error?.code ?? 0)")
            }
        } catch {operationError=error}
        backend.stop()
        try await Task.sleep(nanoseconds:1_000_000_000)
        try await manager.loadFromPreferences()
        manager.protocolConfiguration=original;manager.onDemandRules=rules
        manager.isOnDemandEnabled=demand;manager.isEnabled=enabled
        try await manager.saveToPreferences();try await manager.loadFromPreferences()
        XCTAssertEqual(manager.protocolConfiguration?.serverAddress,original?.serverAddress)
        XCTAssertEqual(manager.isOnDemandEnabled,demand)
        if let operationError {throw operationError}
        XCTAssertTrue(success,"Cold profile did not establish a tunnel; original profile restored")
    }
}
#endif
