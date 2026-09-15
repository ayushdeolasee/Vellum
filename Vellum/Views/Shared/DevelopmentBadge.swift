import SwiftUI

struct DevelopmentBadge: View {
    var body: some View {
        Text("DEV")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.orange, in: Capsule())
            .accessibilityLabel("Development build")
            .accessibilityIdentifier("development-profile-badge")
    }
}
