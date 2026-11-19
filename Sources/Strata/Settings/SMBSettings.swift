import SwiftUI

struct SMBSettingsPane: View {
    let connections: SMBConnections?
    let places: PlaceChecks?

    var body: some View {
        Group {
            if let connections, let places {
                SMBSettings(connections: connections, places: places)
            } else {
                Form { Section(String(localized: "SMB Connections")) {} }
                    .formStyle(.grouped)
                    .modifier(ThemedFormBackground())
            }
        }
        .frame(minHeight: 180)
        .settingAnchor(.smbConnections)
    }
}

private struct SMBSettings: View {
    @ObservedObject var connections: SMBConnections
    let places: PlaceChecks
    @State private var volumes: [Place] = []
    @State private var editing: SMBEditor.Draft?
    @State private var removing: SMBProfile?
    @State private var problem = ""

    var body: some View {
        Form {
            Section(String(localized: "SMB Connections")) {
                ForEach(connections.profiles) { profile in
                    row(profile)
                }
                Button(String(localized: "Add SMB Connection…")) { editing = .init(profile: nil) }
            }
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        .onAppear {
            volumes = places.snapshot.volumes
            places.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .placesChecked, object: places)) { _ in
            volumes = places.snapshot.volumes
        }
        .sheet(item: $editing) { draft in SMBEditor(draft: draft, connections: connections) }
        .confirmationDialog(String(localized: "Remove SMB Connection?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { profile in
            Button(String(localized: "Remove", comment: "Alert button: forget the saved server"), role: .destructive) {
                Task {
                    do { try await connections.remove(profile) }
                    catch let error as ServerConnection.Problem { problem = error.message }
                    catch { problem = error.localizedDescription }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { profile in
            Text(String(localized: "Remove “\(profile.title)” from Strata?", comment: "A saved server's name"))
        }
        .alert(String(localized: "SMB Connections"), isPresented: Binding(
            get: { !problem.isEmpty }, set: { if !$0 { problem = "" } }
        )) { Button(String(localized: "OK"), role: .cancel) {} } message: { Text(problem) }
    }

    private func row(_ profile: SMBProfile) -> some View {
        let connecting = connections.isConnecting(profile.id)
        let mounted = connections.mountedVolume(for: profile, in: volumes)
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.title)
                if !profile.name.isEmpty {
                    Text(profile.shownAddress).font(.caption).foregroundStyle(.secondary)
                }
                if connecting {
                    Text(String(localized: "Connecting…")).font(.caption).foregroundStyle(.secondary)
                } else if mounted != nil {
                    Text(String(localized: "Connected")).font(.caption).foregroundStyle(.secondary)
                } else if let failure = connections.failures[profile.id] {
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                }
                if profile.connectsAtLaunch {
                    Text(String(localized: "Connect at launch")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button(String(localized: "Connect", comment: "Button: connect to the server")) {
                    Task { _ = try? await connections.connect(profile) }
                }
                .disabled(connecting || mounted != nil)
                if let mounted, let address = mounted.remountAddress {
                    Button(String(localized: "Disconnect", comment: "Button: end the connection to the server")) {
                        guard connections.profile(profile.id) == profile else { return }
                        Places.eject(mounted.url, from: NSApp.keyWindow, matchingSMB: address)
                    }
                    .disabled(connecting)
                }
                Button(String(localized: "Edit…", comment: "Sidebar menu: change a saved server's settings")) {
                    editing = .init(profile: profile)
                }
                Button(String(localized: "Remove", comment: "Alert button: forget the saved server"), role: .destructive) {
                    removing = profile
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(String(localized: "SMB Connections"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct SMBEditor: View {
    struct Draft: Identifiable {
        let profile: SMBProfile?
        var id: UUID
        var name: String
        var address: String
        var sharePath: String
        var user: String
        var guest: Bool
        var remember: Bool
        var autoConnect: Bool

        init(profile: SMBProfile?) {
            self.profile = profile
            id = profile?.id ?? UUID()
            name = profile?.name ?? ""
            address = profile?.shownServer ?? ""
            sharePath = profile?.shownSharePath ?? ""
            user = profile?.user ?? ""
            guest = profile?.guest ?? false
            remember = profile?.remembersPassword ?? false
            autoConnect = profile?.connectsAtLaunch ?? false
        }
    }

    @State var draft: Draft
    let connections: SMBConnections
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var problem = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.profile.map { String(localized: "Edit “\($0.title)”", comment: "Sheet title: editing a saved server") }
                 ?? String(localized: "Add SMB Connection…"))
                .font(.headline)
                .padding([.top, .horizontal], 20)
            Form {
                TextField(String(localized: "Name"), text: $draft.name)
                TextField(String(localized: "Server address"), text: $draft.address,
                          prompt: Text(verbatim: "server.local"))
                TextField(String(localized: "Share path"), text: $draft.sharePath,
                          prompt: Text(String(localized: "Optional", comment: "Placeholder: a field that can stay empty")))
                Toggle(String(localized: "Connect as guest"), isOn: $draft.guest)
                if !draft.guest {
                    TextField(String(localized: "User Name"), text: $draft.user)
                    Toggle(String(localized: "Save password in Keychain"), isOn: $draft.remember)
                    if draft.remember {
                        SecureField(String(localized: "Password"), text: $password,
                                    prompt: draft.profile?.remembersPassword == true
                                        ? Text(String(localized: "Leave blank to keep the saved password")) : nil)
                    }
                }
                Toggle(String(localized: "Connect at launch"), isOn: $draft.autoConnect)
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(saving)
            if !problem.isEmpty {
                Text(problem).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", comment: "Button: save the edited server"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.address.isEmpty)
            }
            .padding(20)
            .disabled(saving)
        }
        .frame(width: 500)
        .interactiveDismissDisabled(saving)
        .modifier(ThemedFormBackground())
    }

    private func save() {
        guard !saving else { return }
        problem = ""
        do {
            let profile = try SMBProfile.make(id: draft.id, name: draft.name, address: draft.address,
                sharePath: draft.sharePath, user: draft.user,
                guest: draft.guest, remembersPassword: !draft.guest && draft.remember, connectsAtLaunch: draft.autoConnect)
            saving = true
            Task {
                defer { saving = false }
                do {
                    try await connections.save(profile, replacing: draft.profile, password: password)
                    dismiss()
                } catch let error as ServerConnection.Problem {
                    problem = error.message
                } catch {
                    problem = error.localizedDescription
                }
            }
        } catch let error as ServerConnection.Problem {
            problem = error.message
        } catch {
            problem = error.localizedDescription
        }
    }
}
