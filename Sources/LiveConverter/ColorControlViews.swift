import SwiftUI

struct ColorWheelPad: View {
    let title: String
    @Binding var wheel: ColorGrade.ColorWheel

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)

            ColorWheelField(wheel: $wheel)
                .frame(width: 122, height: 122)

            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: levelBinding, in: -1...1, step: 0.05)
                Text(String(format: "%+.0f", wheel.level * 100))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var levelBinding: Binding<Double> {
        Binding(
            get: { wheel.level },
            set: { value in
                var next = wheel
                next.level = value
                wheel = next
            }
        )
    }
}

private struct ColorWheelField: View {
    @Binding var wheel: ColorGrade.ColorWheel

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = size / 2
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let knob = CGPoint(x: center.x + CGFloat(wheel.x) * radius * 0.88,
                               y: center.y + CGFloat(wheel.y) * radius * 0.88)

            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                          center: .center))
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.95), .clear],
                                         center: .center,
                                         startRadius: 0,
                                         endRadius: radius))
                Circle()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                wheelCrosshair(center: center, radius: radius)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.black.opacity(0.65), lineWidth: 2))
                    .shadow(radius: 1, y: 1)
                    .position(knob)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in updateWheel(at: drag.location, in: proxy.size) }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func wheelCrosshair(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x - radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        return path
    }

    private func updateWheel(at location: CGPoint, in size: CGSize) {
        let radius = min(size.width, size.height) / 2 * 0.88
        guard radius > 0 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var x = (location.x - center.x) / radius
        var y = (location.y - center.y) / radius
        let magnitude = sqrt(x * x + y * y)
        if magnitude > 1 {
            x /= magnitude
            y /= magnitude
        }
        wheel.x = Double(x)
        wheel.y = Double(y)
    }
}

struct ColorWarperPad: View {
    @Binding var warper: ColorGrade.ColorWarper

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                          center: .center))
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.28)],
                                         startPoint: .top,
                                         endPoint: .bottom))
                warperGrid(in: proxy.size)
                    .stroke(Color.white.opacity(0.72), lineWidth: 1.2)

                ForEach(ColorGrade.WarpZone.allCases) { zone in
                    Circle()
                        .fill(color(for: zone))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .position(position(for: zone, in: proxy.size))
                        .help(zone.title)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in update(zone, at: drag.location, in: proxy.size) }
                        )
                }
            }
        }
        .frame(height: 210)
    }

    private func warperGrid(in size: CGSize) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.36
        var path = Path()

        for scale in [0.35, 0.68, 1.0] {
            let vertices = hexagon(center: center, radius: radius * scale)
            path.move(to: vertices[0])
            for point in vertices.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }

        for zone in ColorGrade.WarpZone.allCases {
            let angle = CGFloat(zone.hueDegrees * .pi / 180)
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 1.28,
                                     y: center.y + sin(angle) * radius * 1.28))
        }

        return path
    }

    private func hexagon(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        ColorGrade.WarpZone.allCases.map { zone in
            let angle = CGFloat(zone.hueDegrees * .pi / 180)
            return CGPoint(x: center.x + cos(angle) * radius,
                           y: center.y + sin(angle) * radius)
        }
    }

    private func position(for zone: ColorGrade.WarpZone, in size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let baseRadius = min(size.width, size.height) * 0.36
        let point = warper.point(for: zone)
        let angle = CGFloat((zone.hueDegrees + point.hueShift * 30) * .pi / 180)
        let radius = baseRadius * CGFloat(1 + point.saturation * 0.45)
        return CGPoint(x: center.x + cos(angle) * radius,
                       y: center.y + sin(angle) * radius)
    }

    private func update(_ zone: ColorGrade.WarpZone, at location: CGPoint, in size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let baseRadius = min(size.width, size.height) * 0.36
        guard baseRadius > 0 else { return }
        let dx = location.x - center.x
        let dy = location.y - center.y
        let radius = sqrt(dx * dx + dy * dy)
        let angle = atan2(Double(dy), Double(dx))
        let zoneAngle = zone.hueDegrees * .pi / 180
        let hueShift = min(max(shortestAngle(angle - zoneAngle) / (.pi / 6), -1), 1)
        let saturation = min(max((Double(radius / baseRadius) - 1) / 0.45, -1), 1)

        var next = warper
        next.set(ColorGrade.WarpPoint(hueShift: hueShift, saturation: saturation), for: zone)
        warper = next
    }

    private func shortestAngle(_ radians: Double) -> Double {
        var output = radians.truncatingRemainder(dividingBy: .pi * 2)
        if output > .pi { output -= .pi * 2 }
        if output < -.pi { output += .pi * 2 }
        return output
    }

    private func color(for zone: ColorGrade.WarpZone) -> Color {
        Color(hue: zone.hueDegrees / 360, saturation: 0.92, brightness: 0.95)
    }
}
