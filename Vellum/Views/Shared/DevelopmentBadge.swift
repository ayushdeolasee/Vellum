import SwiftUI

struct DevelopmentBadge: View {
    var body: some View {
        Text("DEV")
            .font(.caption2.weight(.black))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.orange, in: Capsule())
            .accessibilityLabel("Development build")
            .accessibilityIdentifier("development-profile-badge")
    }
}
