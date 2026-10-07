import Foundation
import SideSign

actor ProvisioningManager {
    static let shared = ProvisioningManager()
    private let credentials = CredentialStore()
    private let portal = DeveloperPortal.shared
    private let anisette = AnisetteDataManager()
    private struct SigningMaterial: Codable {
        let certificate: X509Certificate
        let key: Data
    }

    func signIn(email: String, password: String, server: URL,
                verification: @escaping DeveloperPortal.VerificationHandler) async throws -> [Team] {
        guard server.scheme == "https", server.host != nil else { throw RefreshError.message("Use an HTTPS anisette server URL.") }
        let data = try await anisetteData(server: server)
        let auth = try await portal.authenticate(appleID: email, password: password, anisetteData: data,
                                                xcodeVersion: "16.3", machinePassword: nil,
                                                accountRepairHandler: { _, _ in .cancel }, verificationHandler: verification)
        let teams = try await portal.fetchTeams(for: auth.account, session: auth.session)
        try credentials.write(JSONEncoder().encode(auth), for: "session")
        try credentials.write(Data(server.absoluteString.utf8), for: "anisetteServer")
        // A previous team's choice must not cross account boundaries.
        if let previous = try selectedTeam(), !teams.contains(where: { $0.id == previous.id }) { try credentials.remove("team") }
        return teams
    }
    func teams() async throws -> [Team] {
        let auth = try await authenticatedSession()
        return try await portal.fetchTeams(for: auth.account, session: auth.session)
    }
    func select(_ team: Team) throws { try credentials.write(JSONEncoder().encode(team), for: "team") }
    func selectedTeam() throws -> Team? {
        guard let data = try credentials.read("team") else { return nil }
        return try JSONDecoder().decode(Team.self, from: data)
    }
    func certificateExpiration() throws -> Date? {
        guard let team = try selectedTeam(), let data = try credentials.read("signing.\(team.id)") else { return nil }
        return try JSONDecoder().decode(SigningMaterial.self, from: data).certificate.notAfter
    }
    private func anisetteData(server: URL) async throws -> AnisetteData {
        let identifier: UUID
        if let data = try credentials.read("anisetteID"), let value = String(data: data, encoding: .utf8), let uuid = UUID(uuidString: value) { identifier = uuid }
        else { identifier = UUID(); try credentials.write(Data(identifier.uuidString.utf8), for: "anisetteID") }
        let result = try await anisette.fetchAnisetteData(mode: .remote(server: server), identifier: identifier,
                                                        existingAdiBlob: credentials.read("adiBlob"))
        if let blob = result.newAdiBlob { try credentials.write(blob, for: "adiBlob") }
        return result.data
    }
    private func authenticatedSession() async throws -> AuthSession {
        guard let data = try credentials.read("session"),
              let serverData = try credentials.read("anisetteServer"),
              let address = String(data: serverData, encoding: .utf8), let server = URL(string: address) else {
            throw RefreshError.authenticationRequired
        }
        let saved = try JSONDecoder().decode(AuthSession.self, from: data)
        guard saved.session.isValid else { throw RefreshError.authenticationRequired }
        var session = saved.session
        session.anisetteData = try await anisetteData(server: server)
        return AuthSession(account: saved.account, session: session)
    }
    private func signingKey(team: Team, session: Session) async throws -> KeyStore {
        let name = "signing.\(team.id)"
        let certificates = try await portal.fetchCertificates(for: team, session: session)
        if let data = try credentials.read(name) {
            let saved = try JSONDecoder().decode(SigningMaterial.self, from: data)
            if let active = certificates.first(where: { $0.serialNumberHex == saved.certificate.serialNumberHex }),
               let expiry = active.notAfter, expiry > Date().addingTimeInterval(600) {
                return KeyStore(certificate: active, privateKey: saved.key)
            }
        }
        let key = try await portal.addCertificate(machineName: "FreshApple", to: team, session: session)
        try credentials.write(JSONEncoder().encode(SigningMaterial(certificate: key.certificate, key: key.privateKey)), for: name)
        return key
    }
    func sign(appURL: URL, udid: String) async throws -> Date {
        let auth = try await authenticatedSession()
        guard let selected = try selectedTeam() else { throw RefreshError.teamRequired }
        let teams = try await portal.fetchTeams(for: auth.account, session: auth.session)
        guard let team = teams.first(where: { $0.id == selected.id }) else { throw RefreshError.teamRequired }
        let key = try await signingKey(team: team, session: auth.session)
        let devices = try await portal.fetchDevices(for: team, session: auth.session)
        let device: Device
        if let existing = devices.first(where: { $0.identifier == udid }) { device = existing }
        else { device = try await portal.registerDevice(name: "FreshApple iPhone", identifier: udid, type: .iPhone, team: team, session: auth.session) }
        guard let bundle = AppBundle(fileURL: appURL), let certID = key.certificate.identifier,
              let deviceID = device.deviceID else { throw RefreshError.certificateUnavailable }
        var ids = try await portal.fetchAppIDs(for: team, session: auth.session)
        let existingProfiles = try await portal.listProvisioningProfiles(for: team, session: auth.session)
        var profiles: [ProvisioningProfile] = []
        for component in bundle.allAppBundles {
            var appID: AppID
            if let existing = ids.first(where: { $0.bundleIdentifier == component.bundleIdentifier }) { appID = existing }
            else {
                appID = try await portal.addAppID(withName: component.name, bundleIdentifier: component.bundleIdentifier,
                                                  team: team, session: auth.session)
                ids.append(appID)
            }
            // Preserve existing team identity and shared-container identifiers.
            if let previous = component.provisioningProfile, previous.teamIdentifier != team.id {
                throw RefreshError.message("\(component.name) was signed by a different team. Select that team to preserve its identity and Keychain access.")
            }
            var changed = false
            for (name, _) in component.entitlements {
                let entitlement = Entitlement(rawValue: name)
                if let feature = Feature(entitlement: entitlement), appID.features[feature] != "true" {
                    guard team.type.allowedFeatures?.contains(feature) == true else {
                        throw RefreshError.message("Your team does not support \(name), which \(component.name) requires.")
                    }
                    appID.features[feature] = "true"
                    changed = true
                }
            }
            if changed { appID = try await portal.updateAppID(appID, team: team, session: auth.session) }
            if let requestedGroups = component.entitlements["com.apple.security.application-groups"] as? [String], !requestedGroups.isEmpty {
                var available = try await portal.fetchAppGroups(for: team, session: auth.session)
                var groups: [AppGroup] = []
                for identifier in requestedGroups {
                    if let existing = available.first(where: { $0.identifier == identifier }) { groups.append(existing) }
                    else {
                        let group = try await portal.addAppGroup(name: component.name, groupIdentifier: identifier, team: team, session: auth.session)
                        groups.append(group); available.append(group)
                    }
                }
                appID = try await portal.assignAppGroups(groups, to: appID, team: team, session: auth.session)
            }
            let nameKey = "profileName.\(team.id).\(component.bundleIdentifier)"
            let name: String
            if let saved = try credentials.read(nameKey), let value = String(data: saved, encoding: .utf8), !value.isEmpty {
                name = value
            } else {
                name = ProfileRenewal.newName()
                try credentials.write(Data(name.utf8), for: nameKey)
            }
            let candidates = existingProfiles.filter {
                $0.name == name && ($0.bundleIdentifier == nil || $0.bundleIdentifier == component.bundleIdentifier)
            }
            let profile = try await ProfileRenewal.renew(name: name, profileIDs: candidates.compactMap(\.identifier),
                saveName: { try self.credentials.write(Data($0.utf8), for: nameKey) },
                update: { profileID, profileName in
                    // List responses can omit appId; verify the actual profile before changing it.
                    let previous = try await self.portal.downloadProvisioningProfile(profileID: profileID, team: team, session: auth.session)
                    guard previous.bundleIdentifier == component.bundleIdentifier, previous.teamIdentifier == team.id else {
                        throw RefreshError.message("The saved provisioning profile belongs to a different app or team.")
                    }
                    return try await self.portal.updateProvisioningProfile(profileID: profileID, name: profileName, appIDId: appID.identifier,
                        certificateIDs: [certID], deviceIDs: [deviceID], team: team, session: auth.session)
                },
                create: { profileName in
                    try await self.portal.createProvisioningProfile(name: profileName, appID: appID, certificateIDs: [certID],
                        deviceIDs: [deviceID], team: team, session: auth.session)
                })
            guard profile.expirationDate > Date(), profile.teamIdentifier == team.id,
                  profile.bundleIdentifier == component.bundleIdentifier, profile.deviceIDs.contains(udid) else {
                throw RefreshError.message("Apple returned a profile that does not match this app, team, or iPhone.")
            }
            let missing = Set(component.entitlements.keys).subtracting(profile.entitlements.keys)
                .subtracting(["get-task-allow", "application-identifier", "com.apple.developer.team-identifier"])
            guard missing.isEmpty else {
                throw RefreshError.message("The new profile does not support these required entitlements: \(missing.sorted().joined(separator: ", ")). Installation was stopped to preserve the app’s capabilities.")
            }
            profiles.append(profile)
        }
        try Task.checkCancellation()
        try await AppBundleSigner(team: team, keyStore: key).signApp(at: appURL, provisioningProfiles: profiles)
        guard let expiry = profiles.map(\.expirationDate).min() else { throw RefreshError.invalidIPA }
        return expiry
    }
}
