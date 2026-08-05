import SwiftUI
import WidgetKit

@main
struct VellumWidgets: WidgetBundle {
    var body: some Widget {
        RecentDocumentsWidget()
        ReadLaterWidget()
    }
}
