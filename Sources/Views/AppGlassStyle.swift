import SwiftUI

/// Shared adaptive surface: native Liquid Glass on iOS 26+, system material fallback on earlier iOS.
struct AppGlassSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
                }
        }
    }
}

extension View {
    func appGlassSurface(cornerRadius: CGFloat = 18) -> some View {
        modifier(AppGlassSurface(cornerRadius: cornerRadius))
    }
}

struct AppGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label.buttonStyle(.glass)
        } else {
            configuration.label.buttonStyle(.bordered)
        }
    }
}
