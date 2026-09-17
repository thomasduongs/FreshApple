import Foundation
import Minimuxer

actor DeviceConnection {
    static let shared = DeviceConnection()
    private let muxer = Minimuxer.shared()
    private var loadedRecord: String?

    func connect() async throws -> String {
        #if targetEnvironment(simulator)
        throw RefreshError.message("Installation requires a physical iPhone with LocalDevVPN. You can manage source IPAs in the simulator.")
        #else
        let record = try PairingStore().load()
        if loadedRecord != record {
            if loadedRecord != nil { try await muxer.core.stop(); loadedRecord = nil }
            await muxer.core.bindConnectionConfig(ConnectionConfigBinding(
                setTunnelIfaceIp: { _ in }, setTunnelPeerIp: { _ in }, setTunnelPeerSubnetMask: { _ in },
                setTunnelPeerReachable: { _ in }, setTunnelIfaceSubnetMask: { _ in },
                getRemoteServerIp: { "" }, setRemoteReachable: { _ in },
                getOverrideTunnelPeerIp: { "" }, setOverrideTunnelPeerReachable: { _ in },
                getConnectionMode: { .localVPN }))
            try await muxer.core.start(pairingFile: record, mountPath: URL.applicationSupportDirectory.path)
            loadedRecord = record
        }
        await muxer.network.refreshEndpoint()
        let ready = await muxer.core.isReady(withNetworkCheck: true, withDDIMountCheck: false)
        guard (try? ready.get()) == true else { throw RefreshError.vpnUnavailable }
        guard let udid = try await muxer.core.fetchUDID(), !udid.isEmpty else { throw RefreshError.pairingRequired }
        return udid
        #endif
    }
    func stage(appURL: URL, bundleID: String) async throws {
        try await muxer.core.sendAppBundleAfc(bundleId: bundleID, appURL: appURL)
    }
    func install(bundleID: String, appName: String) async throws {
        // Never uninstall: installation_proxy replaces the app in place.
        try await muxer.core.installAppBundle(bundleId: bundleID, appName: appName)
    }
}
