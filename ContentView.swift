import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = RefreshViewModel()
    @State private var showSetup = false
    @State private var showDiagnostics = false
    @State private var importIPA = false
    @Environment(\.scenePhase) private var scenePhase
    private let green = Color(red: 0.16, green: 0.39, blue: 0.26)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    status
                    refreshButton
                    appsSection
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text("Your apps. Your device.")
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 14)
                }
                .padding(.horizontal, 24).padding(.top, 16)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSetup) { SetupView(model: model) }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView(model: model) }
            .fileImporter(isPresented: $importIPA, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { model.importIPA($0) }
            .task { await model.load() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.load() } } }
            .alert("FreshApple", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
        .tint(green)
    }
    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "leaf.fill").font(.title2).foregroundStyle(green)
                Text("FreshApple").font(.system(.title2, design: .rounded, weight: .bold))
            }
            Spacer()
            Button { showSetup = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3).padding(12)
                    .background(.background, in: Circle())
            }.accessibilityLabel("Setup").disabled(model.busy)
        }
    }
    private var status: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(green.opacity(0.08), lineWidth: 13)
                Circle().trim(from: 0, to: ringProgress)
                    .stroke(green, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 3) {
                    Image(systemName: model.success ? "checkmark" : "leaf")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(green).padding(.bottom, 8)
                    if model.busy {
                        Text("\(Int(model.progress.fraction * 100))%")
                            .font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("REFRESHING").font(.system(size: 10, weight: .semibold)).tracking(2)
                    } else if let days = model.daysRemaining {
                        Text("\(days)").font(.system(size: 60, weight: .medium, design: .rounded))
                        Text(days == 1 ? "DAY REMAINING" : "DAYS REMAINING").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                    } else {
                        Text("Stay fresh.").font(.system(.title2, design: .rounded, weight: .medium))
                        Text("READY TO BEGIN").font(.system(size: 10, weight: .semibold)).tracking(1.5).padding(.top, 7)
                    }
                }
            }.frame(width: 220, height: 220).padding(.vertical, 16)
            VStack(spacing: 8) {
                Text(model.busy ? model.progress.message : model.success ? model.progress.message : model.apps.isEmpty ? "A little refresh. A lot more time." : "Keep your apps close.")
                    .font(.system(.headline, design: .rounded)).multilineTextAlignment(.center)
                Text(model.apps.isEmpty ? "Add your apps once. Give them a fresh start\nwith a single tap." : "Connect LocalDevVPN before refreshing.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onLongPressGesture { showDiagnostics = true }
        .accessibilityAction(named: "Show diagnostics") { showDiagnostics = true }
        .animation(.easeInOut(duration: 0.3), value: model.progress.fraction)
    }
    private var ringProgress: CGFloat {
        if model.busy { return max(0.02, model.progress.fraction) }
        if let days = model.daysRemaining { return min(1, Double(days) / 7) }
        return 0.16
    }
    private var refreshButton: some View {
        VStack(spacing: 13) {
            Button {
                if model.apps.isEmpty { importIPA = true }
                else if !model.paired || model.selectedTeam == nil { showSetup = true }
                else { model.refresh() }
            } label: {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().tint(.white) }
                    else { Image(systemName: model.apps.isEmpty ? "plus" : "arrow.clockwise") }
                    Text(model.busy ? "Refreshing…" : model.apps.isEmpty ? "Add your first app" : "Refresh Apps")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 19)
                .foregroundStyle(.white).background(green, in: RoundedRectangle(cornerRadius: 19))
            }.disabled(model.busy).accessibilityIdentifier("refreshButton")
            if let last = model.lastRefresh {
                Text("Last refreshed \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            } else { Text("A fresh start is one tap away").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("YOUR APPS").font(.system(size: 11, weight: .semibold)).tracking(1.7).foregroundStyle(.secondary)
                Spacer()
                Button { importIPA = true } label: { Image(systemName: "plus").font(.subheadline.weight(.semibold)) }
                    .accessibilityLabel("Import IPA").disabled(model.busy)
            }
            if model.apps.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(green).padding(12)
                        .background(green.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A home for your own apps").font(.subheadline.weight(.semibold))
                        Text("Import an IPA from Files to keep its source ready for every refresh.")
                            .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 20))
            } else {
                VStack(spacing: 0) {
                    ForEach(model.apps) { app in
                        HStack(spacing: 12) {
                            Image(systemName: app.isSelf ? "leaf.fill" : "app.dashed")
                                .font(.title2).foregroundStyle(green).frame(width: 46, height: 46)
                                .background(green.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.displayName).font(.subheadline.weight(.semibold))
                                Text("v\(app.version)\(app.isSelf ? " · Refreshes last" : "")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(app.pendingExpiration != nil ? "Verify on launch" : app.daysRemaining().map { $0 == 0 ? "Expired" : "\($0)d left" } ?? "Not refreshed")
                                .font(.caption.weight(.medium)).foregroundStyle(app.daysRemaining() == 0 ? .orange : green)
                        }.padding(16)
                        if app.id != model.apps.last?.id { Divider().padding(.leading, 74) }
                    }
                }.background(.background, in: RoundedRectangle(cornerRadius: 20))
            }
            Button("View diagnostics") { showDiagnostics = true }.font(.caption).frame(maxWidth: .infinity).padding(.top, 4)
        }
    }
}
