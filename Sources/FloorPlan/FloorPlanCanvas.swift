import SwiftUI

/// Vẽ mặt bằng 2D: sàn, tường, cửa, cửa sổ, đồ đạc và kích thước.
struct FloorPlanCanvas: View {
    let model: FloorPlanModel
    var backgroundColor: Color = Color(.systemBackground)
    var showDimensions = true

    var body: some View {
        Canvas { context, size in
            guard !model.isEmpty, model.bounds.width > 0.1, model.bounds.height > 0.1 else {
                return
            }
            let padding: CGFloat = 48
            let scale = min(
                (size.width - padding * 2) / model.bounds.width,
                (size.height - padding * 2) / model.bounds.height
            )
            let offsetX = (size.width - model.bounds.width * scale) / 2
            let offsetY = (size.height - model.bounds.height * scale) / 2

            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(
                    x: (p.x - model.bounds.minX) * scale + offsetX,
                    y: (p.y - model.bounds.minY) * scale + offsetY
                )
            }

            // 1. Sàn nhà
            for polygon in model.floorPolygons {
                var path = Path()
                path.addLines(polygon.map(point))
                path.closeSubpath()
                context.fill(path, with: .color(Color(.secondarySystemBackground)))
            }

            // 2. Đồ đạc
            for object in model.objects {
                let w = object.size.width * scale
                let h = object.size.height * scale
                guard w > 2, h > 2 else { continue }
                let c = point(object.center)
                let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                let transform = CGAffineTransform(translationX: c.x, y: c.y)
                    .rotated(by: object.rotation)
                let path = Path(roundedRect: rect, cornerRadius: min(4, w / 4))
                    .applying(transform)
                context.fill(path, with: .color(Color.blue.opacity(0.10)))
                context.stroke(path, with: .color(Color.blue.opacity(0.45)), lineWidth: 1)

                if w > 34, h > 16 {
                    context.draw(
                        Text(object.label)
                            .font(.system(size: 9))
                            .foregroundColor(.blue.opacity(0.8)),
                        at: c, anchor: .center
                    )
                }
            }

            // 3. Tường
            let wallWidth = max(3, scale * 0.12)
            for wall in model.walls {
                var path = Path()
                path.move(to: point(wall.start))
                path.addLine(to: point(wall.end))
                context.stroke(
                    path,
                    with: .color(.primary),
                    style: StrokeStyle(lineWidth: wallWidth, lineCap: .square)
                )
            }

            // 4. Lối đi thông phòng: xóa đoạn tường, vẽ nét đứt
            for opening in model.openings {
                var gap = Path()
                gap.move(to: point(opening.start))
                gap.addLine(to: point(opening.end))
                context.stroke(
                    gap,
                    with: .color(backgroundColor),
                    style: StrokeStyle(lineWidth: wallWidth + 1, lineCap: .butt)
                )
                context.stroke(
                    gap,
                    with: .color(.secondary),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }

            // 5. Cửa ra vào: xóa đoạn tường + vẽ cánh cửa mở
            for door in model.doors {
                var gap = Path()
                gap.move(to: point(door.start))
                gap.addLine(to: point(door.end))
                context.stroke(
                    gap,
                    with: .color(backgroundColor),
                    style: StrokeStyle(lineWidth: wallWidth + 1, lineCap: .butt)
                )
                let hinge = point(door.start)
                let doorEnd = point(door.end)
                let radius = hypot(doorEnd.x - hinge.x, doorEnd.y - hinge.y)
                let startAngle = atan2(doorEnd.y - hinge.y, doorEnd.x - hinge.x)
                var arc = Path()
                arc.move(to: doorEnd)
                arc.addArc(
                    center: hinge,
                    radius: radius,
                    startAngle: Angle(radians: startAngle),
                    endAngle: Angle(radians: startAngle - .pi / 2),
                    clockwise: true
                )
                arc.addLine(to: hinge)
                context.stroke(arc, with: .color(Color.brown), lineWidth: 1.2)
            }

            // 6. Cửa sổ: nét xanh mảnh đè lên tường
            for window in model.windows {
                var path = Path()
                path.move(to: point(window.start))
                path.addLine(to: point(window.end))
                context.stroke(
                    path,
                    with: .color(backgroundColor),
                    style: StrokeStyle(lineWidth: wallWidth - 1, lineCap: .butt)
                )
                context.stroke(
                    path,
                    with: .color(Color.cyan),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .butt)
                )
            }

            // 7. Kích thước tường
            if showDimensions {
                for wall in model.walls where wall.lengthMeters >= 0.7 {
                    let mid = point(wall.midpoint)
                    var angle = wall.angle
                    // Giữ chữ luôn xuôi chiều đọc
                    if angle > .pi / 2 { angle -= .pi }
                    if angle < -.pi / 2 { angle += .pi }
                    let normal = CGPoint(x: -sin(angle), y: cos(angle))
                    let labelPoint = CGPoint(
                        x: mid.x + normal.x * (wallWidth + 9),
                        y: mid.y + normal.y * (wallWidth + 9)
                    )
                    var layer = context
                    layer.translateBy(x: labelPoint.x, y: labelPoint.y)
                    layer.rotate(by: Angle(radians: angle))
                    layer.draw(
                        Text(String(format: "%.2f m", wall.lengthMeters))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary),
                        at: .zero, anchor: .center
                    )
                }
            }
        }
    }
}
