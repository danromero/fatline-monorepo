import SwiftUI

/// A network that hasn't let you in yet: an empty dashed tile where its mark would be.
struct NetworkWaitingMark: View {
    var size = FatlineStyle.avatarSize

    var body: some View {
        RoundedRectangle(cornerRadius: size * FatlineStyle.markRadiusRatio, style: .continuous)
            .strokeBorder(FatlineStyle.outline, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
