import CoreLocation
import SwiftUI

/// If Wi-Fi drops: the iPhone hotspot to join and the tmux panes to nudge.
/// The name field suggests networks this Mac has joined and still takes any
/// name typed. The password is loaded once each time the sheet opens, so
/// an edit never outlives the sheet it was made in.
struct HotspotSheet: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    /// Finds nearby network names for the priority list.
    var scanner: any HotspotScanning = CoreWLANHotspotScanner()
    /// Finds nearby phones and tablets for the priority list.
    var nearbyDevices: any NearbyHotspotBrowsing = SharingHotspotBrowser()

    @Environment(\.dismiss) private var dismiss
    /// The password field, saving, what was saved, and the notice under
    /// the field.
    @State private var hotspot = HotspotPasswordField()
    /// Networks this Mac has joined, offered as hotspot names.
    @State private var knownNetworks: [String] = []
    @State private var newTmuxTarget = ""

    var body: some View {
        Form {
            hotspotSection
            joinTimingSection
            tmuxSection
        }
        .formStyle(.grouped)
        // No fixed height: macOS fits a sheet to its rows up to a height it
        // takes from the Settings window, and the form scrolls the rest. A
        // long tmux list then keeps Done on screen and scrolls to Add.
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    // A save that fails after the sheet closes would put its
                    // notice in a sheet no one sees.
                    .disabled(hotspot.saving)
            }
        }
        .interactiveDismissDisabled(hotspot.saving)
        .task {
            knownNetworks = CoreWLANHotspotJoiner.rememberedNetworks()
            await loadPassword()
        }
        // Names appear once Location access is allowed.
        .onChange(of: locationPermission.authorizationStatus) {
            knownNetworks = CoreWLANHotspotJoiner.rememberedNetworks()
        }
        // The failover may find the saved password unreadable while the
        // sheet is open, and an SSID edit makes the notice about another
        // hotspot's item: the notice follows both.
        .onChange(of: manager.services?.status.hotspotPasswordReport) { recheckPassword() }
        .onChange(of: HotspotSSID.normalized(manager.config.hotspotSSID)) { recheckPassword() }
    }

    private var hotspotSection: some View {
        Section {
            Toggle("Join several hotspots in priority order", isOn: hotspotPriority)
                .onChange(of: manager.config.hotspotPriorityEnabled) { manager.services?.hotspotSettingsChanged() }
            if manager.config.hotspotPriorityEnabled {
                PriorityHotspotList(
                    manager: manager,
                    secrets: secrets,
                    locationPermission: locationPermission,
                    scanner: scanner,
                    devices: nearbyDevices,
                    update: { manager.updateConfig($0) }
                )
            } else {
                singleHotspotRows
            }
            LabeledContent {
                locationAccess
            } label: {
                Text("Location access")
                // macOS has no when-in-use grant for Mac apps: the grant is
                // recorded as Location Services access for Insomnia.
                Text(
                    "macOS needs it to show Wi-Fi network names. "
                        + "Insomnia never reads your location.")
            }
        } header: {
            Text("iPhone hotspot")
        } footer: {
            Text(
                "If Wi-Fi drops during a session, Insomnia joins this hotspot, or with the priority list "
                    + "on, the highest one on the list in range. Passwords stay in your login keychain; "
                    + "after a reinstall, enter them again.")
        }
    }

    /// Turning the list on starts it with the hotspot above, if there is
    /// one and the list is empty (`Config.setHotspotPriority`).
    private var hotspotPriority: Binding<Bool> {
        Binding(
            get: { manager.config.hotspotPriorityEnabled },
            set: { on in manager.updateConfig { $0.setHotspotPriority(on) } }
        )
    }

    private var joinTimingSection: some View {
        Section {
            Toggle(isOn: manager.binding(\.aggressiveHotspotJoin)) {
                Text("Join a hotspot as soon as Wi-Fi drops (aggressive)")
                Text(
                    "Off, Insomnia first gives macOS 20 seconds to rejoin the Wi-Fi network it dropped, "
                        + "so a blip at home does not wake your hotspot. When a hotspot Insomnia joined "
                        + "drops, the next one is joined after 5 seconds either way.")
            }
        }
    }

    /// The one hotspot's name and password, with the priority list off.
    @ViewBuilder
    private var singleHotspotRows: some View {
        TextField(
            "Hotspot name", text: manager.binding(\.hotspotSSID),
            prompt: Text("Choose or type a name")
        )
        .textInputSuggestions {
            ForEach(suggestions, id: \.self) { name in
                Label(name, systemImage: "wifi")
                    .textInputCompletion(name)
            }
        }
        LabeledContent("Password") {
            HStack {
                SecureField(
                    "Password",
                    text: Binding(get: { hotspot.password }, set: { hotspot.edit($0) }),
                    prompt: Text("Required")
                )
                .labelsHidden()
                .onSubmit(savePassword)
                Button(
                    hotspot.buttonTitle(ssid: manager.config.hotspotSSID),
                    action: savePassword)
                    .disabled(hotspot.password.isEmpty || hotspot.saving)
            }
        }
        if let notice = hotspot.notice {
            Text(notice).font(.caption).foregroundStyle(.orange)
        }
    }

    private var suggestions: [String] {
        HotspotSSID.suggestions(for: manager.config.hotspotSSID, among: knownNetworks)
    }

    /// The Location status, or the one button that changes it.
    @ViewBuilder
    private var locationAccess: some View {
        switch locationPermission.authorizationStatus {
        case .notDetermined:
            Button("Allow\u{2026}") { locationPermission.requestWhenInUse() }
        case .denied:
            Button("Open Location Services") { locationPermission.openLocationServicesSettings() }
        default:
            Text(locationPermission.statusDescription).foregroundStyle(.secondary)
        }
    }

    private var tmuxSection: some View {
        Section {
            DisclosureGroup("Type \"continue\" into tmux after an outage") {
                Stepper(value: nudgeSeconds, in: 10...900, step: 10) {
                    LabeledContent(
                        "After", value: "\(Int(manager.config.nudgeThreshold)) s offline")
                }
                Text(
                    "Only panes marked with this command are nudged. "
                        + "Mark a pane you don't type in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(TmuxNudge.markCommand())
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Toggle(isOn: manager.binding(\.tmuxNudgePressesEnter)) {
                    Text("Press Enter after continue")
                    Text("Enter also submits anything already typed in that pane.")
                }
                ForEach(manager.config.tmuxTargets, id: \.self) { target in
                    LabeledContent {
                        Button("Remove", systemImage: "minus.circle.fill") {
                            manager.updateConfig { $0.tmuxTargets.removeAll { $0 == target } }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                    } label: {
                        Text(target).font(.system(.body, design: .monospaced))
                    }
                }
                HStack {
                    TextField("Pane", text: $newTmuxTarget, prompt: Text("session:window.pane"))
                        .labelsHidden()
                        .onSubmit(addTmuxTarget)
                    Button("Add", action: addTmuxTarget)
                        .disabled(newTmuxTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var nudgeSeconds: Binding<Int> {
        Binding(
            get: { Int(manager.config.nudgeThreshold) },
            set: { seconds in manager.updateConfig { $0.nudgeThreshold = TimeInterval(seconds) } })
    }

    private func addTmuxTarget() {
        let target = newTmuxTarget.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        manager.updateConfig { config in
            if !config.tmuxTargets.contains(target) { config.tmuxTargets.append(target) }
        }
        newTmuxTarget = ""
    }

    // MARK: Password

    /// Fills the field when the sheet opens (`loadForField`).
    private func loadPassword() async {
        let request = hotspot.startLoad(ssid: manager.config.hotspotSSID)
        await HotspotPasswordField.loadForField(request, secrets: secrets) {
            hotspot.finishRead(
                $0, ssid: manager.config.hotspotSSID, password: $1.password, notice: $1.notice)
        }
    }

    /// Reads the notice again for the hotspot configured now, without a
    /// prompt and without touching the field.
    private func recheckPassword() {
        recheckPassword(hotspot.startRead(ssid: manager.config.hotspotSSID))
    }

    private func recheckPassword(_ request: HotspotPasswordField.Read) {
        Task {
            await HotspotPasswordField.readForField(
                request,
                first: { await recheckedNotice() },
                again: { await recheckedNotice() },
                finish: {
                    hotspot.finishRead(
                        $0, ssid: manager.config.hotspotSSID, password: $1.password,
                        notice: $1.notice)
                }
            )
        }
    }

    private func recheckedNotice() async -> (password: String, notice: String?) {
        let notice = await HotspotPasswordField.hotspotNotice(
            reported: manager.services?.status.hotspotPasswordReport,
            ssid: manager.config.hotspotSSID,
            reread: secrets.peek
        )
        return ("", notice)
    }

    /// Saves, or clears for an empty field. The button shows "Saving…"
    /// until the keychain answers; one save at a time.
    private func savePassword() {
        guard hotspot.startSave() else { return }
        if !HotspotSSID.normalized(manager.config.hotspotSSID).isEmpty {
            locationPermission.requestWhenInUse()
        }
        let password = hotspot.password
        Task {
            let outcome = await HotspotPasswordField.storePassword(password, in: secrets)
            let recheck = hotspot.finishSave(outcome, ssid: manager.config.hotspotSSID)
            // The failover's report first, so the recheck reads it as the
            // save left it.
            HotspotPasswordField.passwordStored(
                outcome, configuredSSID: manager.config.hotspotSSID, services: manager.services)
            if let recheck { recheckPassword(recheck) }
        }
    }
}
