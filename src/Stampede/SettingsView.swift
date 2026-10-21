import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Clipboard history") {
                Picker(
                    "History Limit",
                    selection: Binding(get: { model.history.capacity }, set: { model.setCapacity($0) })
                ) {
                    Text("5 items").tag(5)
                    Text("10 items").tag(10)
                    Text("20 items").tag(20)
                }.disabled(!model.ready)
                Toggle("Capture new copies", isOn: Binding(get: { !model.paused }, set: { _ in model.togglePause() }))
                    .disabled(!model.ready)
                Text("Pausing only stops saving new copies. Normal copy and paste keep working.").font(.caption)
                if !model.storageStatus.isEmpty {
                    Text(model.storageStatus).font(.caption).textSelection(.enabled)
                }
                Button("Retry History Storage") { model.retry() }.disabled(!model.setupComplete)
            }
            Section("Startup") {
                Toggle(
                    "Launch Stampede at login",
                    isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) })
                )
                Text(model.loginStatus).font(.caption)
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            Section("Clipboard access") {
                Text(
                    "Clipboard access lets Stampede read text and images you copy in other apps and save it to history."
                )
                .font(.caption)
                Text(model.accessState.summary).font(.caption).bold()
                HStack {
                    Button("Check Clipboard Access") { model.requestAccess() }.disabled(!model.ready)
                    Button("Open System Settings…") { model.openSystemSettings() }
                }
                if let feedback = model.accessFeedback {
                    Text(feedback).font(.caption).textSelection(.enabled)
                        .accessibilityLabel("Clipboard access check: \(feedback)")
                }
                if model.accessRequired {
                    Text(
                        "In System Settings, search for clipboard or paste permissions under Privacy & Security, then allow Stampede. Background capture waits while permission requires a prompt."
                    )
                    .font(.caption)
                }
            }
            Section("Privacy & iPad") {
                Text(
                    "Text and image history is encrypted on this Mac and kept across restarts. Unmarked passwords may be captured. Pause capture or clear history when needed."
                )
                Text(
                    "Selecting an item makes it the active clipboard for normal paste. Apple Universal Clipboard shares the active item with nearby devices using the same Apple Account, with Handoff, Bluetooth, and Wi-Fi enabled. Saved history stays on this Mac."
                )
                Text("Restarting restores your list without replacing your Mac or iPad clipboard.")
            }.font(.caption)
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 520, height: 720)
        .onAppear {
            model.refreshLoginStatus()
            model.refreshClipboardAccess()
        }
    }
}
