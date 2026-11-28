import SwiftUI

/// Settings ▸ Appearance: light or dark, row spacing and the size of file names.
struct AppearanceSettings: View {
    private let preferences: Prefs
    @State private var theme: Int
    @State private var density: Int
    @State private var size: Double
    @State private var alternatingRows: Bool
    @State private var previews: Bool

    init(preferences: Prefs) {
        self.preferences = preferences
        _theme = State(initialValue: preferences.theme)
        _density = State(initialValue: preferences.density)
        _size = State(initialValue: preferences.nameTextSize)
        _alternatingRows = State(initialValue: preferences.alternatingRows)
        _previews = State(initialValue: preferences.showIconPreviews)
    }

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: Binding(get: { theme }, set: { theme = $0; preferences.theme = $0 })) {
                    Text("Match the System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.radioGroup).settingAnchor(.appearance)
            }
            Section("Files") {
                Picker("Density", selection: Binding(get: { density }, set: { density = $0; preferences.density = $0 })) {
                    Text("Compact").tag(0)
                    Text("Regular").tag(1)
                    Text("Spacious").tag(2)
                }
                .pickerStyle(.segmented).settingAnchor(.density)
                HStack {
                    Text("Text size")
                    Slider(value: Binding(get: { size }, set: { size = $0.rounded(); preferences.nameTextSize = $0.rounded() }), in: Prefs.nameTextSizes, step: 1) {
                        Text("Text size")
                    } minimumValueLabel: {
                        Text(verbatim: "A").font(.system(size: 10))
                    } maximumValueLabel: {
                        Text(verbatim: "A").font(.system(size: 16))
                    }
                    // The row has its own label; the slider's is for VoiceOver only.
                    .labelsHidden()
                    Text("\(Int(size)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }.settingAnchor(.textSize)
                Text("Quarterly Report.pdf", comment: "Settings ▸ Appearance: a sample file name showing the text size")
                    .font(.system(size: size))
                    .padding(.vertical, [2.0, 5.0, 9.0][min(max(density, 0), 2)])
                    .accessibilityLabel("Preview of a file name at this size")
                Toggle("Alternating row colors", isOn: Binding(get: { alternatingRows }, set: { alternatingRows = $0; preferences.alternatingRows = $0 })).settingAnchor(.alternatingRows)
                Toggle(isOn: Binding(get: { previews }, set: { previews = $0; preferences.showIconPreviews = $0 })) {
                    Text("Show icon previews")
                    Text("Pictures, documents and movies show a thumbnail of their contents in place of their icon.")
                }.settingAnchor(.iconPreviews)
                Text("Applies to the list, columns and icons in every window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                PrefToggle(title: "Show status bar", caption: nil,
                           get: { preferences.showStatusBar }, set: { preferences.showStatusBar = $0 }).settingAnchor(.statusBar)
            }
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        // ⌘+ / ⌘− in the list change the size while this is open.
        .onReceive(preferences.notifications.publisher(for: .appearanceChanged)) { _ in
            if size != preferences.nameTextSize { size = preferences.nameTextSize }
            if theme != preferences.theme { theme = preferences.theme }
        }
        .onReceive(preferences.notifications.publisher(for: .alternatingRowsChanged, object: preferences)) { _ in alternatingRows = preferences.alternatingRows }
    }
}
