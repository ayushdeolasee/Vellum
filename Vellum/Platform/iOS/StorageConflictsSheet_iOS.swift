#if os(iOS)
import SwiftUI

struct StorageConflictsSheet_iOS: View {
    @Binding var conflicts: [StorageCoordinator.ArchivedConflict]

    var body: some View {
        StorageConflictsView(conflicts: $conflicts)
    }
}
#endif
