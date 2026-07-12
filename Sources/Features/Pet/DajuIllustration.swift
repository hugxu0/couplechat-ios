import SwiftUI

/// 代码绘制的静态 2D 大橘。它也是远端场景素材加载失败时的永久可用回退。
struct DajuIllustration: View {
    var isResponding = false

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                CatTailShape()
                    .stroke(
                        Color(red: 0.78, green: 0.34, blue: 0.12),
                        style: StrokeStyle(lineWidth: size * 0.105, lineCap: .round))
                    .frame(width: size * 0.75, height: size * 0.66)
                    .offset(x: size * 0.22, y: size * 0.13)

                Ellipse()
                    .fill(catGradient)
                    .frame(width: size * 0.58, height: size * 0.64)
                    .offset(y: size * 0.16)

                frontPaws(size)
                head(size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(isResponding ? 1.035 : 1)
        }
        .aspectRatio(0.86, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var catGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1.00, green: 0.68, blue: 0.27),
                Color(red: 0.92, green: 0.43, blue: 0.13),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    private func head(_ size: CGFloat) -> some View {
        ZStack {
            CatEarShape()
                .fill(Color(red: 0.92, green: 0.43, blue: 0.13))
                .frame(width: size * 0.28, height: size * 0.31)
                .offset(x: -size * 0.18, y: -size * 0.25)
                .rotationEffect(.degrees(-10))
            CatEarShape()
                .fill(Color(red: 0.92, green: 0.43, blue: 0.13))
                .frame(width: size * 0.28, height: size * 0.31)
                .offset(x: size * 0.18, y: -size * 0.25)
                .scaleEffect(x: -1, y: 1)
                .rotationEffect(.degrees(10))
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(catGradient)
                .frame(width: size * 0.68, height: size * 0.53)
                .offset(y: -size * 0.12)
            face(size)
        }
    }

    private func face(_ size: CGFloat) -> some View {
        ZStack {
            HStack(spacing: size * 0.19) {
                Capsule()
                    .fill(Color(red: 0.22, green: 0.14, blue: 0.11))
                    .frame(width: size * 0.045, height: size * 0.075)
                Capsule()
                    .fill(Color(red: 0.22, green: 0.14, blue: 0.11))
                    .frame(width: size * 0.045, height: size * 0.075)
            }
            .offset(y: -size * 0.17)

            CatMuzzleShape()
                .fill(Color(red: 1.00, green: 0.84, blue: 0.57))
                .frame(width: size * 0.25, height: size * 0.15)
                .offset(y: -size * 0.05)
            Circle()
                .fill(Color(red: 0.40, green: 0.19, blue: 0.14))
                .frame(width: size * 0.052, height: size * 0.052)
                .offset(y: -size * 0.09)
            CatMouthShape()
                .stroke(
                    Color(red: 0.40, green: 0.19, blue: 0.14),
                    style: StrokeStyle(lineWidth: max(1.5, size * 0.012), lineCap: .round))
                .frame(width: size * 0.12, height: size * 0.07)
                .offset(y: -size * 0.025)
        }
    }

    private func frontPaws(_ size: CGFloat) -> some View {
        HStack(spacing: size * 0.10) {
            Capsule().fill(catGradient)
            Capsule().fill(catGradient)
        }
        .frame(width: size * 0.37, height: size * 0.34)
        .offset(y: size * 0.35)
    }
}

struct PetRoomBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.99, green: 0.91, blue: 0.88),
                        Color(red: 0.96, green: 0.90, blue: 0.89),
                        Color(red: 0.98, green: 0.94, blue: 0.85),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                window(width: width, height: height)
                floor(width: width, height: height)
                shelf(width: width, height: height)
            }
        }
        .accessibilityHidden(true)
    }

    private func window(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.78, green: 0.90, blue: 0.95))
            Circle()
                .fill(Color(red: 1.00, green: 0.80, blue: 0.38).opacity(0.8))
                .frame(width: min(width, height) * 0.16)
                .offset(x: width * 0.10, y: -height * 0.08)
            Rectangle()
                .fill(.white.opacity(0.55))
                .frame(width: 4)
            Rectangle()
                .fill(.white.opacity(0.55))
                .frame(height: 4)
        }
        .frame(width: width * 0.58, height: height * 0.46)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.8), lineWidth: 8)
        }
        .offset(y: -height * 0.17)
    }

    private func floor(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(red: 0.73, green: 0.50, blue: 0.35).opacity(0.18))
                .frame(width: width, height: height * 0.33)
            Ellipse()
                .fill(Color(red: 0.97, green: 0.54, blue: 0.48).opacity(0.20))
                .frame(width: width * 0.60, height: height * 0.16)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func shelf(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(red: 0.57, green: 0.35, blue: 0.24).opacity(0.55))
            .frame(width: width * 0.30, height: 9)
            .offset(x: -width * 0.29, y: height * 0.18)
    }
}

private struct CatEarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control1: CGPoint(x: rect.width * 0.34, y: rect.height * 0.72),
            control2: CGPoint(x: rect.width * 0.72, y: rect.height * 0.70))
        path.addLine(to: CGPoint(x: rect.width * 0.30, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct CatTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.35, y: rect.height * 0.82))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.82, y: rect.height * 0.20),
            control1: CGPoint(x: rect.width * 0.98, y: rect.height * 1.02),
            control2: CGPoint(x: rect.width * 1.02, y: rect.height * 0.44))
        return path
    }
}

private struct CatMuzzleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 0, y: 0, width: rect.width * 0.58, height: rect.height))
        path.addEllipse(in: CGRect(
            x: rect.width * 0.42, y: 0, width: rect.width * 0.58, height: rect.height))
        return path
    }
}

private struct CatMouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.height * 0.48),
            control1: CGPoint(x: rect.width * 0.42, y: rect.height * 0.50),
            control2: CGPoint(x: rect.width * 0.20, y: rect.height * 0.58))
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.48),
            control1: CGPoint(x: rect.width * 0.58, y: rect.height * 0.50),
            control2: CGPoint(x: rect.width * 0.80, y: rect.height * 0.58))
        return path
    }
}
