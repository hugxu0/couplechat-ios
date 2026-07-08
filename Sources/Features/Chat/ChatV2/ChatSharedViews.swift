import SwiftUI

struct CatHeadIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: w * 0.24, y: h * 0.43))
        path.addLine(to: CGPoint(x: w * 0.20, y: h * 0.12))
        path.addLine(to: CGPoint(x: w * 0.39, y: h * 0.29))
        path.addQuadCurve(to: CGPoint(x: w * 0.61, y: h * 0.29), control: CGPoint(x: w * 0.50, y: h * 0.22))
        path.addLine(to: CGPoint(x: w * 0.80, y: h * 0.12))
        path.addLine(to: CGPoint(x: w * 0.76, y: h * 0.43))
        path.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.86), control: CGPoint(x: w * 0.82, y: h * 0.74))
        path.addQuadCurve(to: CGPoint(x: w * 0.24, y: h * 0.43), control: CGPoint(x: w * 0.18, y: h * 0.74))

        path.move(to: CGPoint(x: w * 0.38, y: h * 0.50))
        path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.54))
        path.move(to: CGPoint(x: w * 0.62, y: h * 0.50))
        path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.54))
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.60))
        path.addQuadCurve(to: CGPoint(x: w * 0.43, y: h * 0.67), control: CGPoint(x: w * 0.47, y: h * 0.64))
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.60))
        path.addQuadCurve(to: CGPoint(x: w * 0.57, y: h * 0.67), control: CGPoint(x: w * 0.53, y: h * 0.64))

        return path
    }
}

extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }

    func messageSearchHighlight(_ highlighted: Bool) -> some View {
        self
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: DS.Radius.bubble + 5, style: .continuous)
                        .stroke(DS.Palette.accent.opacity(0.9), lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.bubble + 5, style: .continuous)
                                .fill(DS.Palette.accent.opacity(0.14))
                        )
                        .padding(-5)
                }
            }
            .shadow(color: highlighted ? DS.Palette.accent.opacity(0.28) : .clear, radius: 12, y: 2)
    }
}
