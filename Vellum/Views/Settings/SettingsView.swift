import SwiftUI

/// App settings window (⌘, / Vellum ▸ Settings…). Home of the light/dark
/// theme switch, which used to live in the toolbar.
struct SettingsView: View {
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        Form {
            Picker("Appearance", selection: themeBinding) {
                Text("Light").tag(AppTheme.light)
                Text("Dark").tag(AppTheme.dark)
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { themeStore.theme },
            set: { themeStore.setTheme($0) }
        )
    }
}
