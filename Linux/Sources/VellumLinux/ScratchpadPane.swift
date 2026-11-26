import CShell
import Foundation
import LinuxReader
import VellumCore

@MainActor
final class ScratchpadPane {
    // GdkTexture is immutable and documented as thread-safe. GTK widget
    // installation stays on the startup pthread.
    private final class Preview: @unchecked Sendable {
        let id: String
        let texture: OpaquePointer

        init?(_ image: ScratchpadStorage.Image) {
            guard let texture = image.data.withUnsafeBytes({ bytes in
                scratchpad_image_decode(image.format, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }) else { return nil }
            self.id = image.id
            self.texture = texture
        }

        deinit { scratchpad_image_release(texture) }

        @concurrent static func decode(_ images: [ScratchpadStorage.Image]) async -> [Preview] {
            images.compactMap { Task.isCancelled ? nil : Preview($0) }
        }
    }

    private struct Draft {
        var text: String
        var baseline: Data?
        var savedText: String
        var previews: [Preview]
        let hasUnavailableImages: Bool
        var staged: [ScratchpadStorage.Image] = []
        var message: String?
        var dirty: Bool { !text.utf8.elementsEqual(savedText.utf8) }
    }

    private let panel: OpaquePointer
    private let storage: ScratchpadStorage
    private var key: String?
    private var drafts: [String: Draft] = [:]
    private var generation = 0
    private var load: Task<Void, Never>?
    private var attach: Task<Void, Never>?
    private var save: Task<Void, Never>?
    private var savingKey: String?
    private var selectionMessage = ""
    private var preparingImage = false
    private var closed = false

    init(panel: OpaquePointer, storage: ScratchpadStorage) {
        self.panel = panel
        self.storage = storage
        if let directory = storage.importDirectory {
            scratchpad_panel_set_import_directory(panel, directory.path)
        }
        scratchpad_panel_connect(panel, { event, text, context in
            precondition(shell_on_gtk_thread())
            MainActor.assumeIsolated {
                let pane = Unmanaged<ScratchpadPane>.fromOpaque(context!).takeUnretainedValue()
                pane.handle(event, text: text.map { String(cString: $0) })
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func beginSelection() {
        retarget(nil, message: "Opening document…")
    }

    func select(_ key: String?) {
        retarget(key, message: key == nil
                 ? "This document has no shared scratchpad identity."
                 : "Loading scratchpad…")
    }

    private func retarget(_ next: String?, message: String) {
        generation += 1
        load?.cancel()
        attach?.cancel()
        preparingImage = false
        if let key, key != savingKey, drafts[key]?.dirty == false {
            drafts.removeValue(forKey: key)
        }
        key = next
        selectionMessage = message
        showDraft()
        loadIfNeeded()
    }

    private func handle(_ event: ScratchpadEvent, text: String?) {
        guard !closed else { return }
        if event == SCRATCHPAD_SHOW {
            loadIfNeeded()
            return
        }
        guard let key, var draft = drafts[key], storage.canEdit, key != savingKey else { return }
        switch event {
        case SCRATCHPAD_CHANGE:
            guard let text else { return }
            draft.text = text
            draft.message = nil
            drafts[key] = draft
            updateState()
        case SCRATCHPAD_SAVE:
            guard draft.dirty, !preparingImage, save == nil else { return }
            save = Task {
                _ = await commit(key)
                save = nil
                updateState()
            }
        case SCRATCHPAD_ATTACH:
            guard let text else { return }
            prepareImage(at: URL(fileURLWithPath: text), for: key)
        default:
            break
        }
    }

    private func loadIfNeeded() {
        guard scratchpad_panel_visible(panel), let key, drafts[key] == nil, !closed else { return }
        let prior = load
        let token = generation
        prior?.cancel()
        load = Task {
            await prior?.value
            guard isCurrent(token) else { return }
            do {
                let note = try await storage.load(key)
                let previews = await Preview.decode(note.images)
                guard isCurrent(token) else { return }
                drafts[key] = Draft(text: note.text, baseline: note.baseline,
                                    savedText: note.text, previews: previews,
                                    hasUnavailableImages: note.unavailableImages > 0 ||
                                        previews.count != note.images.count)
                showDraft()
            } catch {
                guard isCurrent(token) else { return }
                selectionMessage = "Could not read scratchpad. \(describe(error))"
                updateState()
            }
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        generation == token && !closed && !Task.isCancelled
    }

    private func prepareImage(at url: URL, for key: String) {
        let prior = attach
        let token = generation
        preparingImage = true
        updateState()
        prior?.cancel()
        attach = Task {
            await prior?.value
            guard isCurrent(token) else { return }
            defer {
                if isCurrent(token) {
                    preparingImage = false
                    updateState()
                }
            }
            do {
                let image = try await storage.prepareImage(url)
                let preview = await Preview.decode([image]).first
                guard isCurrent(token), var draft = drafts[key], key != savingKey else { return }
                guard let preview else { throw ScratchpadStorage.Failure.unsupportedImage }
                if !draft.text.isEmpty { draft.text += "\n\n" }
                draft.text += image.markdown
                draft.staged.append(image)
                draft.previews.append(preview)
                scratchpad_panel_add_image(panel, preview.texture)
                draft.message = nil
                drafts[key] = draft
                scratchpad_panel_set_note(panel, draft.text)
            } catch {
                guard isCurrent(token) else { return }
                drafts[key]?.message = describe(error)
            }
        }
    }

    private func commit(_ key: String) async -> Bool {
        guard var draft = drafts[key], draft.dirty else { return true }
        savingKey = key
        updateState()
        defer {
            savingKey = nil
            updateState()
        }
        do {
            draft.baseline = try await storage.save(key, text: draft.text,
                                                   baseline: draft.baseline, staged: draft.staged)
            let referenced = await ScratchpadStorage.referencedImageIDs(in: draft.text)
            if key == self.key {
                draft.savedText = draft.text
                draft.staged = []
                draft.previews.removeAll { !referenced.contains($0.id) }
                draft.message = "Scratchpad saved."
                drafts[key] = draft
                showImages(draft.previews)
            } else {
                drafts.removeValue(forKey: key)
            }
            return true
        } catch {
            drafts[key]?.message = "Save failed. \(describe(error))"
            return false
        }
    }

    // Call with input paused. A failed save keeps every unsaved draft in this pane.
    func flush() async -> Bool {
        await attach?.value
        await save?.value
        for key in drafts.keys.sorted() {
            guard await commit(key) else {
                scratchpad_panel_show(panel)
                if key == self.key {
                    updateState()
                } else {
                    scratchpad_panel_set_state(panel,
                        "A scratchpad for another document could not be saved. Reopen it to see its draft.",
                        false, false, false)
                }
                return false
            }
        }
        return true
    }

    func shutdown() async {
        closed = true
        scratchpad_panel_disconnect(panel)
        load?.cancel()
        attach?.cancel()
        await load?.value
        await attach?.value
        await save?.value
    }

    private func showDraft() {
        guard !closed else { return }
        let draft = key.flatMap { drafts[$0] }
        scratchpad_panel_set_note(panel, draft?.text ?? "")
        showImages(draft?.previews ?? [])
        updateState()
    }

    private func showImages(_ previews: [Preview]) {
        guard !closed else { return }
        scratchpad_panel_clear_images(panel)
        for preview in previews { scratchpad_panel_add_image(panel, preview.texture) }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case LibraryFileError.io(let reason): reason
        case LibraryFileError.retryable: "The note changed during the save. Your draft is still here."
        case LibraryFileError.symbolicLink, LibraryFileError.outsideAllowedRoot:
            "Only regular files inside this library are available."
        case ReaderFileError.fileTooLarge: "The file exceeds the scratchpad size limit."
        default: error.localizedDescription
        }
    }

    private func updateState() {
        guard !closed else { return }
        guard let key, let draft = drafts[key] else {
            scratchpad_panel_set_state(panel, selectionMessage, false, false, false)
            return
        }
        let message: String
        if key == savingKey {
            message = "Saving scratchpad…"
        } else if let status = draft.message {
            message = status
        } else if storage.canEdit {
            message = draft.dirty ? "Unsaved changes" : "Shared scratchpad"
        } else {
            message = draft.text.isEmpty ? "No saved scratchpad · Read only" : "Scratchpad · Read only"
        }
        let images = draft.hasUnavailableImages ? "\nSome referenced images could not be displayed." : ""
        scratchpad_panel_set_state(panel, message + images,
                                   key != savingKey && !preparingImage, storage.canEdit,
                                   draft.dirty && !preparingImage && save == nil && savingKey == nil)
    }
}
