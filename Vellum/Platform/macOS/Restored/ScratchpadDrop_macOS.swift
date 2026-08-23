#if os(macOS)
import Foundation

extension ScratchpadStore {
    func handleDrop(_ payload: AttachmentDropPayload) -> Bool {
        switch payload {
        case let .files(urls):
            guard let url = urls.first else {
                warnUnsupportedDrop()
                return true
            }
            Task { [weak self] in
                let capture = await Task.detached(priority: .userInitiated) {
                    () -> ScratchpadImageCapture? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return scratchpadCapture(from: data)
                }.value
                guard let self else { return }
                if let capture { self.addImage(capture, label: "Image") }
                else { self.warnUnsupportedDrop() }
            }
        case let .imageData(data, _):
            Task { [weak self] in
                let capture = await Task.detached(priority: .userInitiated) {
                    () -> ScratchpadImageCapture? in
                    scratchpadCapture(from: data)
                }.value
                guard let self else { return }
                if let capture { self.addImage(capture, label: "Image") }
                else { self.warnUnsupportedDrop() }
            }
        }
        return true
    }
}
#endif
