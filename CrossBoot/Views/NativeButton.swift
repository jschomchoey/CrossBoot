import SwiftUI

/// Full-width action button styled to match the rest of the window
struct NativeButton: View {
    var title: String
    var isEnabled: Bool
    var isSecondary: Bool = false
    var action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(backgroundGradient)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var gradientColors: [Color] {
        if !isEnabled {
            let base = Color(NSColor.controlBackgroundColor)
            return [base, base.opacity(0.8)]
        }

        if isSecondary {
            let base = Color(NSColor.controlBackgroundColor)
            if isPressed {
                return [base.opacity(0.6), base.opacity(0.7)]
            }
            if isHovered {
                return [base.opacity(0.9), base]
            }
            return [base.opacity(0.8), base.opacity(0.9)]
        }

        // The primary button keeps one fixed gradient; hover and pressed states
        // were deliberately dropped from its theme.
        let accent = Color(NSColor.controlAccentColor)
        return [accent.opacity(0.8), accent]
    }

    private var textColor: Color {
        if !isEnabled {
            return Color(NSColor.disabledControlTextColor)
        }
        if isSecondary {
            return Color(NSColor.labelColor)
        }
        return .white
    }

    private var borderColor: Color {
        isEnabled && !isSecondary ? .clear : Color(NSColor.separatorColor)
    }
}

#Preview {
    VStack(spacing: 12) {
        NativeButton(title: "Create Bootable Drive", isEnabled: true, action: {})
        NativeButton(title: "Abort", isEnabled: true, isSecondary: true, action: {})
        NativeButton(title: "Create Bootable Drive", isEnabled: false, action: {})
    }
    .padding()
    .frame(width: 400)
}
