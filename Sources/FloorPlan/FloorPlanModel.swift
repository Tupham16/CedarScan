import Foundation
import CoreGraphics
import simd
import RoomPlan

struct PlanSegment: Identifiable {
    enum Kind {
        case wall
        case door
        case window
        case opening
    }

    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var kind: Kind
    var lengthMeters: CGFloat

    var midpoint: CGPoint {
        CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    var angle: CGFloat {
        atan2(end.y - start.y, end.x - start.x)
    }
}

struct PlanObject: Identifiable {
    let id = UUID()
    var center: CGPoint
    var size: CGSize
    var rotation: CGFloat
    var label: String
}

/// Chiếu dữ liệu 3D của RoomPlan xuống mặt phẳng XZ (nhìn từ trên xuống) để vẽ mặt bằng 2D.
/// straighten = true (mặc định): NẮN THẲNG kiểu Matterport — xoay từng phòng về trục chung
/// và kéo các tường gần vuông về đúng 0°/90° (chiều dài giữ nguyên, chỉ chỉnh góc).
struct FloorPlanModel {
    var walls: [PlanSegment] = []
    var doors: [PlanSegment] = []
    var windows: [PlanSegment] = []
    var openings: [PlanSegment] = []
    var objects: [PlanObject] = []
    var floorPolygons: [[CGPoint]] = []
    var areaSquareMeters: Double = 0
    var bounds: CGRect = .zero

    var isEmpty: Bool { walls.isEmpty && floorPolygons.isEmpty }

    /// Hình học của MỘT phòng (giữ riêng để xoay cả phòng khi nắn thẳng).
    private struct RoomPiece {
        var walls: [PlanSegment] = []
        var doors: [PlanSegment] = []
        var windows: [PlanSegment] = []
        var openings: [PlanSegment] = []
        var objects: [PlanObject] = []
        var polygons: [[CGPoint]] = []
    }

    init(rooms: [CapturedRoom], straighten: Bool = true) {
        var pieces: [RoomPiece] = rooms.map { room in
            var piece = RoomPiece()
            piece.walls = room.walls.map { Self.segment(for: $0) }
            piece.doors = room.doors.map { Self.segment(for: $0) }
            piece.windows = room.windows.map { Self.segment(for: $0) }
            piece.openings = room.openings.map { Self.segment(for: $0) }
            piece.objects = room.objects.map { Self.planObject(for: $0) }
            piece.polygons = room.floors.compactMap { floor in
                let polygon = Self.floorPolygon(for: floor)
                return polygon.count >= 3 ? polygon : nil
            }
            return piece
        }

        if straighten {
            Self.straightenPieces(&pieces)
        }

        for piece in pieces {
            walls.append(contentsOf: piece.walls)
            doors.append(contentsOf: piece.doors)
            windows.append(contentsOf: piece.windows)
            openings.append(contentsOf: piece.openings)
            objects.append(contentsOf: piece.objects)
            for polygon in piece.polygons {
                floorPolygons.append(polygon)
                areaSquareMeters += Self.polygonArea(polygon)
            }
        }
        bounds = Self.computeBounds(of: self)
    }

    // MARK: - Nắn thẳng (ép vuông kiểu Matterport)

    /// Phòng lệch tối đa bao nhiêu độ thì được xoay về trục chung.
    private static let maxRoomCorrection = 8.0 * .pi / 180
    /// Tường lệch tối đa bao nhiêu độ so với 0°/90° thì được kéo thẳng.
    private static let maxWallSnap = 6.0 * .pi / 180

    private static func straightenPieces(_ pieces: inout [RoomPiece]) {
        // 1. Trục chủ đạo TOÀN CỤC từ mọi bức tường (gập góc về chu kỳ 90°)
        guard let globalAxis = dominantAngle(pieces.flatMap(\.walls)) else { return }

        // 2. Xoay TỪNG PHÒNG (cứng, quanh tâm phòng) về trục chung nếu chỉ lệch nhẹ
        for index in pieces.indices {
            guard let roomAxis = dominantAngle(pieces[index].walls) else { continue }
            let delta = foldAngle(roomAxis - globalAxis)
            if abs(delta) > 0.0005, abs(delta) <= maxRoomCorrection {
                rotate(&pieces[index], by: -delta, around: centroid(of: pieces[index]))
            }
        }

        // 3. Xoay CẢ BẢN VẼ để trục chủ đạo nằm ngang màn hình (nhìn chuyên nghiệp)
        let globalDelta = foldAngle(globalAxis)
        if abs(globalDelta) > 0.0005 {
            let allCenter = overallCentroid(of: pieces)
            for index in pieces.indices {
                rotate(&pieces[index], by: -globalDelta, around: allCenter)
            }
        }

        // 4. Kéo từng tường/cửa/cửa sổ gần vuông về ĐÚNG 0°/90° (xoay quanh trung điểm — dài không đổi)
        for index in pieces.indices {
            snapSegments(&pieces[index].walls)
            snapSegments(&pieces[index].doors)
            snapSegments(&pieces[index].windows)
            snapSegments(&pieces[index].openings)
            for objIndex in pieces[index].objects.indices {
                let r = foldAngle(pieces[index].objects[objIndex].rotation)
                if abs(r) <= maxWallSnap {
                    pieces[index].objects[objIndex].rotation -= r
                }
            }
        }
    }

    /// Hướng tường chủ đạo (trung bình tròn trên góc x4 — tường vuông góc tính chung 1 hướng).
    private static func dominantAngle(_ segments: [PlanSegment]) -> CGFloat? {
        var x: CGFloat = 0
        var y: CGFloat = 0
        for segment in segments {
            let angle = segment.angle
            let weight = max(segment.lengthMeters, 0.1)
            x += weight * cos(4 * angle)
            y += weight * sin(4 * angle)
        }
        guard abs(x) > 0.0001 || abs(y) > 0.0001 else { return nil }
        return atan2(y, x) / 4
    }

    /// Gập một góc về khoảng (-45°, 45°] theo chu kỳ 90°.
    private static func foldAngle(_ angle: CGFloat) -> CGFloat {
        atan2(sin(4 * angle), cos(4 * angle)) / 4
    }

    private static func rotatePoint(_ p: CGPoint, around c: CGPoint, by angle: CGFloat) -> CGPoint {
        let dx = p.x - c.x
        let dy = p.y - c.y
        return CGPoint(
            x: c.x + dx * cos(angle) - dy * sin(angle),
            y: c.y + dx * sin(angle) + dy * cos(angle)
        )
    }

    private static func rotate(_ piece: inout RoomPiece, by angle: CGFloat, around center: CGPoint) {
        func rotateSegments(_ segments: inout [PlanSegment]) {
            for i in segments.indices {
                segments[i].start = rotatePoint(segments[i].start, around: center, by: angle)
                segments[i].end = rotatePoint(segments[i].end, around: center, by: angle)
            }
        }
        rotateSegments(&piece.walls)
        rotateSegments(&piece.doors)
        rotateSegments(&piece.windows)
        rotateSegments(&piece.openings)
        for i in piece.objects.indices {
            piece.objects[i].center = rotatePoint(piece.objects[i].center, around: center, by: angle)
            piece.objects[i].rotation += angle
        }
        for i in piece.polygons.indices {
            piece.polygons[i] = piece.polygons[i].map { rotatePoint($0, around: center, by: angle) }
        }
    }

    private static func snapSegments(_ segments: inout [PlanSegment]) {
        for i in segments.indices {
            let delta = foldAngle(segments[i].angle)
            guard abs(delta) > 0.0005, abs(delta) <= maxWallSnap else { continue }
            let mid = segments[i].midpoint
            segments[i].start = rotatePoint(segments[i].start, around: mid, by: -delta)
            segments[i].end = rotatePoint(segments[i].end, around: mid, by: -delta)
        }
    }

    private static func centroid(of piece: RoomPiece) -> CGPoint {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var count = 0
        for segment in piece.walls {
            sumX += segment.start.x + segment.end.x
            sumY += segment.start.y + segment.end.y
            count += 2
        }
        guard count > 0 else { return .zero }
        return CGPoint(x: sumX / CGFloat(count), y: sumY / CGFloat(count))
    }

    private static func overallCentroid(of pieces: [RoomPiece]) -> CGPoint {
        let centers = pieces.map { centroid(of: $0) }
        guard !centers.isEmpty else { return .zero }
        return CGPoint(
            x: centers.reduce(0) { $0 + $1.x } / CGFloat(centers.count),
            y: centers.reduce(0) { $0 + $1.y } / CGFloat(centers.count)
        )
    }

    // MARK: - Geometry helpers

    private static func worldXZ(_ transform: simd_float4x4, _ local: simd_float3) -> CGPoint {
        let world = transform * simd_float4(local.x, local.y, local.z, 1)
        return CGPoint(x: CGFloat(world.x), y: CGFloat(world.z))
    }

    private static func segment(for surface: CapturedRoom.Surface) -> PlanSegment {
        let kind: PlanSegment.Kind
        switch surface.category {
        case .door: kind = .door
        case .window: kind = .window
        case .opening: kind = .opening
        default: kind = .wall
        }

        let transform = surface.transform
        let center = CGPoint(
            x: CGFloat(transform.columns.3.x),
            y: CGFloat(transform.columns.3.z)
        )
        var direction = CGPoint(
            x: CGFloat(transform.columns.0.x),
            y: CGFloat(transform.columns.0.z)
        )
        let magnitude = sqrt(direction.x * direction.x + direction.y * direction.y)
        if magnitude > 0.0001 {
            direction = CGPoint(x: direction.x / magnitude, y: direction.y / magnitude)
        } else {
            direction = CGPoint(x: 1, y: 0)
        }
        let half = CGFloat(surface.dimensions.x) / 2
        return PlanSegment(
            start: CGPoint(x: center.x - direction.x * half, y: center.y - direction.y * half),
            end: CGPoint(x: center.x + direction.x * half, y: center.y + direction.y * half),
            kind: kind,
            lengthMeters: CGFloat(surface.dimensions.x)
        )
    }

    private static func planObject(for object: CapturedRoom.Object) -> PlanObject {
        let transform = object.transform
        let center = CGPoint(
            x: CGFloat(transform.columns.3.x),
            y: CGFloat(transform.columns.3.z)
        )
        let rotation = atan2(
            CGFloat(transform.columns.0.z),
            CGFloat(transform.columns.0.x)
        )
        return PlanObject(
            center: center,
            size: CGSize(
                width: CGFloat(object.dimensions.x),
                height: CGFloat(object.dimensions.z)
            ),
            rotation: rotation,
            label: object.category.vietnameseName
        )
    }

    private static func floorPolygon(for floor: CapturedRoom.Surface) -> [CGPoint] {
        let corners = floor.polygonCorners
        if corners.count >= 3 {
            return corners.map { worldXZ(floor.transform, $0) }
        }
        // Sàn hình chữ nhật: dựng 4 góc từ kích thước bề mặt.
        let halfX = floor.dimensions.x / 2
        let halfY = floor.dimensions.y / 2
        let localCorners: [simd_float3] = [
            simd_float3(-halfX, -halfY, 0),
            simd_float3(halfX, -halfY, 0),
            simd_float3(halfX, halfY, 0),
            simd_float3(-halfX, halfY, 0)
        ]
        return localCorners.map { worldXZ(floor.transform, $0) }
    }

    private static func polygonArea(_ polygon: [CGPoint]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum: Double = 0
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    private static func computeBounds(of model: FloorPlanModel) -> CGRect {
        var points: [CGPoint] = []
        for segment in model.walls + model.doors + model.windows + model.openings {
            points.append(segment.start)
            points.append(segment.end)
        }
        for polygon in model.floorPolygons {
            points.append(contentsOf: polygon)
        }
        for object in model.objects {
            let radius = max(object.size.width, object.size.height) / 2
            points.append(CGPoint(x: object.center.x - radius, y: object.center.y - radius))
            points.append(CGPoint(x: object.center.x + radius, y: object.center.y + radius))
        }
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
