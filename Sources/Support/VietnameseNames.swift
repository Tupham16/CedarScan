import RoomPlan

extension CapturedRoom.Object.Category {
    var vietnameseName: String {
        switch self {
        case .storage: return "Tủ"
        case .refrigerator: return "Tủ lạnh"
        case .stove: return "Bếp"
        case .bed: return "Giường"
        case .sink: return "Bồn rửa"
        case .washerDryer: return "Máy giặt"
        case .toilet: return "Toilet"
        case .bathtub: return "Bồn tắm"
        case .oven: return "Lò nướng"
        case .dishwasher: return "Máy rửa chén"
        case .table: return "Bàn"
        case .sofa: return "Sofa"
        case .chair: return "Ghế"
        case .fireplace: return "Lò sưởi"
        case .television: return "TV"
        case .stairs: return "Cầu thang"
        @unknown default: return "Đồ vật"
        }
    }
}
