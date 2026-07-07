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

    init(rooms: [CapturedRoom]) {
        for room in rooms {
            walls.append(contentsOf: room.walls.map { Self.segment(for: $0) })
            doors.append(contentsOf: room.doors.map { Self.segment(for: $0) })
            windows.append(contentsOf: room.windows.map { Self.segment(for: $0) })
            openings.append(contentsOf: room.openings.map { Self.segment(for: $0) })
            objects.append(contentsOf: room.objects.map { Self.planObject(for: $0) })

            for floor in room.floors {
                let polygon = Self.floorPolygon(for: floor)
                if polygon.count >= 3 {
                    floorPolygons.append(polygon)
                    areaSquareMeters += Self.polygonArea(polygon)
                }
            }
        }
        bounds = Self.computeBounds(of: self)
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
