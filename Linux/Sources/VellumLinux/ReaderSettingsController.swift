import CShell
import Foundation
import LinuxServices
import VellumCore

@MainActor
final class ReaderSettingsController {
    private(set) var provider = ReaderPreferences.defaultProvider
    private var work: Task<Void, Never>?
    private var closing = false

    func configure(provider: LinuxAIProvider, panel: OpaquePointer) {
        self.provider = provider
        for choice in LinuxAIProvider.allCases {
            reader_settings_add_provider(panel, choice.title)
        }
        showProvider(panel: panel)
    }

    func handle(_ event: ReaderEvent, index: Int, text: UnsafePointer<CChar>?, panel: OpaquePointer) {
        guard work == nil, !closing else { return }
        if event == READER_CHANGE_PROVIDER {
            let options = LinuxAIProvider.allCases
            guard options.indices.contains(index), options[index] != provider else { return }
            let chosen = options[index]
            start("Saving provider…", panel: panel) {
                do {
                    try await ReaderPreferences().saveProvider(chosen)
                    self.provider = chosen
                    self.showProvider(panel: panel)
                } catch {
                    self.showProvider(panel: panel, message: "Could not save provider.")
                }
                guard !self.closing else { return }
                if reader_settings_key_is_open(panel) {
                    await self.checkKey(panel: panel)
                } else {
                    reader_settings_set_key(panel, "", false, false)
                }
            }
            return
        }

        let provider = self.provider
        switch event {
        case READER_CHECK_KEY:
            start("Checking keyring…", panel: panel) {
                await self.checkKey(panel: panel)
            }
        case READER_SAVE_KEY:
            guard let text else { return }
            let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            start("Saving key…", panel: panel) {
                let result = await SecretServiceStore().write(value, account: provider.credentialAccount,
                                                              service: LinuxAIProvider.credentialService)
                guard !self.closing else { return }
                if result == .saved {
                    reader_settings_set_key(panel, "Key saved.", false, true)
                } else {
                    await self.checkKey(panel: panel, failure: "Could not save key.")
                }
            }
        case READER_REMOVE_KEY:
            start("Removing key…", panel: panel) {
                let removed = await SecretServiceStore().delete(provider.credentialAccount,
                                                                service: LinuxAIProvider.credentialService)
                guard !self.closing else { return }
                if removed {
                    reader_settings_set_key(panel, "No key saved.", false, false)
                } else {
                    await self.checkKey(panel: panel, failure: "Could not remove key.")
                }
            }
        default:
            preconditionFailure("Unknown settings event")
        }
    }

    func beginClose() -> Task<Void, Never>? {
        closing = true
        return work
    }

    private func start(_ message: String, panel: OpaquePointer, operation: @escaping @MainActor () async -> Void) {
        reader_settings_set_key(panel, message, true, false)
        work = Task {
            await operation()
            work = nil
        }
    }

    private func showProvider(panel: OpaquePointer, message: String = "") {
        guard !closing, let index = LinuxAIProvider.allCases.firstIndex(of: provider) else { return }
        reader_settings_set_provider(panel, UInt32(index), message)
    }

    private func checkKey(panel: OpaquePointer, failure: String? = nil) async {
        let result = await provider.readCredential()
        guard !closing else { return }
        switch result {
        case .value:
            reader_settings_set_key(panel, failure ?? "Key saved.", false, true)
        case .missing:
            reader_settings_set_key(panel, failure ?? "No key saved.", false, false)
        case .unavailable:
            let message = "Keyring is locked or unavailable."
            reader_settings_set_key(panel, failure.map { "\($0) \(message)" } ?? message, false, false)
        }
    }
}
