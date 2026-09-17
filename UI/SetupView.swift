import SwiftUI
import UniformTypeIdentifiers
import SideSign

struct SetupView: View {
    @ObservedObject var model: RefreshViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @AppStorage("anisetteURL") private var server = ""
    @AppStorage("manifestURL") private var manifest = ""
    @State private var importPairing = false
    @State private var code = ""
    @State private var notificationStatus = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("A one-time setup, then one tap.", systemImage: "leaf")
                    Text("Install FreshApple on your iPhone using your Mac. Enable Developer Mode, import the pairing record, and connect LocalDevVPN.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("1 · Pair this iPhone") {
                    Label(model.paired ? "Pairing record saved securely" : "Pairing record needed", systemImage: model.paired ? "checkmark.circle.fill" : "cable.connector")
                    Button(model.paired ? "Replace pairing record" : "Import pairing record") { importPairing = true }
                    Button("Test LocalDevVPN connection") { Task { await model.testConnection() } }
                    Text(model.connectionStatus).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Apple Account email", text: $email).textContentType(.username)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    TextField("Anisette server · https://…", text: $server).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        model.signIn(email: email, password: password, server: server)
                        password = ""
                    } label: {
                        HStack { Text(model.authenticating ? "Signing in…" : "Sign in"); if model.authenticating { Spacer(); ProgressView() } }
                    }.disabled(model.authenticating || email.isEmpty || password.isEmpty || server.isEmpty)
                    if model.authenticating { Button("Cancel sign-in", role: .cancel) { model.cancelSignIn() } }
                    if let request = model.verificationRequest {
                        verificationFields(request)
                    }
                } header: { Text("2 · Apple Account") } footer: {
                    Text("Use an anisette server you trust. Anisette supplies device authentication data; your password goes to Apple and is never saved by FreshApple. Your session and signing key stay in this device’s Keychain.")
                }
                Section("3 · Developer team") {
                    if let team = model.selectedTeam { LabeledContent("Selected", value: team.name); Text(team.id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    else { Text("Sign in, then choose your team.").foregroundStyle(.secondary) }
                    ForEach(model.teams) { team in
                        Button { Task { await model.selectTeam(team.id) } } label: {
                            HStack { Text(team.name); Spacer(); if model.selectedTeam?.id == team.id { Image(systemName: "checkmark") } }
                        }
                    }
                    Button("Load available teams") { Task { await model.loadTeams() } }.disabled(model.authenticating)
                    Text("FreshApple reuses its development certificate. The first refresh creates one if needed.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Build manifest · https://…", text: $manifest).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Optional. Checks imported apps for new builds before refreshing. The manifest must include each IPA’s SHA-256 checksum.").font(.caption).foregroundStyle(.secondary)
                } header: { Text("Build updates") }
                Section("Automation") {
                    Button("Enable expiration reminders") {
                        Task {
                            do {
                                let granted = try await ExpirationNotifications.request()
                                notificationStatus = granted ? "Reminders enabled for 48 hours before expiration." : "Notifications are off. Enable them in iOS Settings."
                                if granted { await ExpirationNotifications.schedule(model.apps) }
                            } catch { notificationStatus = error.localizedDescription }
                        }
                    }
                    if !notificationStatus.isEmpty { Text(notificationStatus).font(.caption) }
                    Text("In Shortcuts, enable LocalDevVPN before running FreshApple’s Refresh Apps action. Background refresh is best effort; iOS chooses when it runs.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $importPairing, allowedContentTypes: [.data, .propertyList]) { model.importPairing($0) }
            .alert("Setup needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .onDisappear { password = ""; model.cancelSignIn() }
        }
    }
    @ViewBuilder
    private func verificationFields(_ request: TwoFactorRequest) -> some View {
        if let error = request.error { Text(error).font(.caption).foregroundStyle(.orange) }
        switch request {
        case .selectDeliveryMethod(_, let phones):
            Text("Choose how to receive your verification code.").font(.subheadline)
            Button("Use a trusted Apple device") { model.verify(.requestTrustedDevice) }
            phoneDeliveryButtons(phones)
        case .trustedDevice:
            verificationCodeField("Enter the code shown on your trusted Apple device.")
            Button("Resend to trusted device") { model.verify(.requestTrustedDevice) }
        case .sms(let phones, _, _):
            verificationCodeField("Enter the code sent by text message.")
            phoneDeliveryButtons(phones)
        case .voice(let phones, _, _):
            verificationCodeField("Enter the code from the verification call.")
            phoneDeliveryButtons(phones)
        }
    }

    @ViewBuilder
    private func phoneDeliveryButtons(_ phones: [TrustedPhoneNumber]) -> some View {
        ForEach(phones) { phone in
            Button("Text \(phone.number)") { code = ""; model.verify(.requestSMS(phoneID: phone.id)) }
            Button("Call \(phone.number)") { code = ""; model.verify(.requestVoice(phoneID: phone.id)) }
        }
    }

    @ViewBuilder
    private func verificationCodeField(_ instructions: String) -> some View {
        Text(instructions).font(.caption)
        TextField("Verification code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
        Button("Verify") {
            model.verify(.verificationCode(code.trimmingCharacters(in: .whitespacesAndNewlines)))
            code = ""
        }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).count != 6)
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: RefreshViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Prerequisites") {
                    LabeledContent("Pairing", value: model.paired ? "Record imported" : "Required")
                    LabeledContent("Team", value: model.selectedTeam?.name ?? "Not selected")
                    LabeledContent("Certificate", value: model.certificateExpiry?.formatted(date: .abbreviated, time: .omitted) ?? "Created on first refresh")
                    LabeledContent("Connection", value: model.connectionStatus)
                    Button("Check connection") { Task { await model.testConnection() } }.disabled(model.busy)
                }
                Section("Provisioning profiles") {
                    ForEach(model.apps) { app in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.displayName).font(.headline)
                            Text(app.bundleIdentifier).font(.caption.monospaced())
                            Text(app.expirationDate.map { "Expires \($0.formatted())" } ?? "No confirmed installation yet").font(.caption).foregroundStyle(.secondary)
                            if app.pendingExpiration != nil { Text("Self-install awaiting verification").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                Section("Activity") {
                    if model.events.isEmpty { Text("No refresh activity yet.").foregroundStyle(.secondary) }
                    ForEach(model.events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.message).font(.subheadline)
                            Text(event.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.load() }
        }
    }
}
