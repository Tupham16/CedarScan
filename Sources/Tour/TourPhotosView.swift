import SwiftUI
import PhotosUI
import UIKit

/// Màn upload ảnh listing cho Virtual Tour: khách gán 1-3 ảnh cho MỖI PHÒNG,
/// đội Cedar247 sẽ ghim ảnh vào đúng vị trí phòng trên floor plan → trang tour chia sẻ được.
struct TourPhotosView: View {
    @Environment(\.dismiss) private var dismiss
    let orderId: String

    @State private var tour: OrderTourResponse?
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var uploadingRooms: Set<String> = [] // key phòng đang upload
    @State private var selectedScanId: String? // tầng đang thao tác (đơn nhiều tầng)
    @State private var customRoomName = ""
    @State private var showCustomRoom = false
    @State private var extraRooms: [String] = [] // phòng vừa thêm nhưng chưa có ảnh

    /// Gợi ý tên phòng (giá trị lưu = TIẾNG ANH — hiện trên trang tour cho người xem nước ngoài)
    private static let suggestions = [
        "Kitchen", "Living Room", "Dining Room", "Bedroom", "Bathroom",
        "Office", "Hallway", "Laundry", "Garage", "Balcony", "Exterior",
    ]

    private var maxPerRoom: Int { tour?.maxPerRoom ?? 3 }
    private var isPublished: Bool { tour?.status == "published" }
    private var scans: [TourScanDTO] { tour?.scans ?? [] }
    private var currentScanId: String? {
        if scans.count <= 1 { return scans.first?.id }
        return selectedScanId ?? scans.first?.id
    }

    /// Ảnh của tầng đang chọn, nhóm theo phòng (giữ thứ tự phòng xuất hiện).
    private var roomGroups: [(room: String, photos: [TourPhotoDTO])] {
        let photos = (tour?.photos ?? []).filter {
            $0.status == "ready" && (scans.count <= 1 || $0.scanId == currentScanId)
        }
        var order: [String] = []
        var map: [String: [TourPhotoDTO]] = [:]
        for p in photos {
            if map[p.roomLabel] == nil { order.append(p.roomLabel) }
            map[p.roomLabel, default: []].append(p)
        }
        for r in extraRooms where map[r] == nil {
            order.append(r)
            map[r] = []
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let tour, tour.hasTour {
                    content
                } else if tour != nil {
                    Text(L.t("This order does not include the Virtual Tour add-on.",
                             "Đơn này không có gói Virtual Tour."))
                        .foregroundStyle(.secondary)
                        .padding(24)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Text(loadError).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L.t("Retry", "Thử lại")) {
                            self.loadError = nil
                            Task { await load() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(24)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L.t("Tour photos", "Ảnh cho tour"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.t("Done", "Xong")) { dismiss() }
                }
            }
            .task { await load() }
            .alert(L.t("Room name", "Tên phòng"), isPresented: $showCustomRoom) {
                TextField(L.t("e.g. Guest Room", "vd Guest Room"), text: $customRoomName)
                Button(L.t("Add", "Thêm")) {
                    let name = customRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, !extraRooms.contains(name) { extraRooms.append(name) }
                    customRoomName = ""
                }
                Button(L.t("Cancel", "Hủy"), role: .cancel) { customRoomName = "" }
            } message: {
                Text(L.t("Use English so viewers can read it on the tour page.",
                         "Nên dùng tiếng Anh để người xem trang tour đọc được."))
            }
        }
    }

    private func load() async {
        do {
            var result = try await APIClient.shared.orderTour(orderId: orderId)
            // Lần đầu mở màn: dọn ảnh "pending" mồ côi (upload dở bị ngắt) để không chiếm slot 3 ảnh/phòng.
            // Chỉ làm khi tour == nil (chưa có upload nào đang chạy từ màn này).
            if tour == nil, let stale = result.photos?.filter({ $0.status == "pending" }), !stale.isEmpty {
                for photo in stale {
                    _ = try? await APIClient.shared.deleteTourPhoto(orderId: orderId, photoId: photo.id)
                }
                result = try await APIClient.shared.orderTour(orderId: orderId)
            }
            tour = result
            errorMessage = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var content: some View {
        Form {
            Section {
                Text(L.t(
                    "Add 1–3 photos per room. Our team will pin them to the right spot on your floor plan and you'll get a shareable tour link with your delivery.",
                    "Thêm 1–3 ảnh cho mỗi phòng. Đội ngũ sẽ ghim ảnh vào đúng vị trí trên mặt bằng — khi giao hàng bạn sẽ nhận link tour để chia sẻ."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                if isPublished {
                    Label(
                        L.t("The tour has been delivered — photos are locked. Contact support for changes.",
                            "Tour đã được giao — ảnh đã khoá. Liên hệ hỗ trợ nếu cần đổi."),
                        systemImage: "lock.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
                if let urlString = tour?.tourUrl, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Label(L.t("View your Virtual Tour", "Xem Virtual Tour của bạn"), systemImage: "house.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if scans.count > 1 {
                Section {
                    Picker(L.t("Floor", "Tầng"), selection: Binding(
                        get: { currentScanId ?? "" },
                        set: { selectedScanId = $0 }
                    )) {
                        ForEach(scans) { s in
                            Text(s.name).tag(s.id)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            ForEach(roomGroups, id: \.room) { group in
                Section {
                    RoomPhotosRow(
                        orderId: orderId,
                        room: group.room,
                        scanId: currentScanId,
                        photos: group.photos,
                        maxPerRoom: maxPerRoom,
                        locked: isPublished,
                        uploading: uploadingRooms.contains(group.room),
                        onUpload: { items in uploadPhotos(items, room: group.room) },
                        onDelete: { photo in deletePhoto(photo) }
                    )
                } header: {
                    Text(group.room)
                }
            }

            if !isPublished {
                Section {
                    Menu {
                        ForEach(Self.suggestions.filter { s in !roomGroups.contains { $0.room == s } }, id: \.self) { s in
                            Button(s) { extraRooms.append(s) }
                        }
                        Divider()
                        Button(L.t("Custom room…", "Phòng khác…")) { showCustomRoom = true }
                    } label: {
                        Label(L.t("Add a room", "Thêm phòng"), systemImage: "plus.circle.fill")
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    private func uploadPhotos(_ items: [PhotosPickerItem], room: String) {
        guard !items.isEmpty else { return }
        uploadingRooms.insert(room)
        errorMessage = nil
        Task {
            defer { uploadingRooms.remove(room) }
            for item in items {
                do {
                    guard let raw = try await item.loadTransferable(type: Data.self),
                          let jpeg = TourPhotoResizer.jpegData(from: raw) else {
                        errorMessage = L.t("Could not read that photo.", "Không đọc được ảnh đó.")
                        continue
                    }
                    let slot = try await APIClient.shared.createTourPhoto(
                        orderId: orderId, roomLabel: room, scanId: currentScanId
                    )
                    try await APIClient.shared.uploadData(jpeg, to: slot.putUrl, contentType: slot.contentType)
                    _ = try await APIClient.shared.completeTourPhoto(orderId: orderId, photoId: slot.photoId)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            await load()
        }
    }

    private func deletePhoto(_ photo: TourPhotoDTO) {
        Task {
            do {
                _ = try await APIClient.shared.deleteTourPhoto(orderId: orderId, photoId: photo.id)
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Một hàng phòng: thumbnail các ảnh đã có + nút thêm (PhotosPicker) + xoá.
private struct RoomPhotosRow: View {
    let orderId: String
    let room: String
    let scanId: String?
    let photos: [TourPhotoDTO]
    let maxPerRoom: Int
    let locked: Bool
    let uploading: Bool
    let onUpload: ([PhotosPickerItem]) -> Void
    let onDelete: (TourPhotoDTO) -> Void

    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(photos) { photo in
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: URL(string: photo.url)) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.gray.opacity(0.15)
                            }
                        }
                        .frame(width: 92, height: 69)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        if !locked {
                            Button {
                                onDelete(photo)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white, .red)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
                if uploading {
                    ProgressView()
                        .frame(width: 92, height: 69)
                }
                if !locked && photos.count < maxPerRoom && !uploading {
                    PhotosPicker(
                        selection: $picked,
                        maxSelectionCount: maxPerRoom - photos.count,
                        matching: .images
                    ) {
                        VStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("\(photos.count)/\(maxPerRoom)").font(.caption2)
                        }
                        .frame(width: 92, height: 69)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                        )
                    }
                    .onChange(of: picked) { _, items in
                        guard !items.isEmpty else { return }
                        onUpload(items)
                        picked = []
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Nén ảnh trước khi upload: co về tối đa 2048px cạnh dài, JPEG 80% (ảnh listing đủ nét, nhẹ mạng).
enum TourPhotoResizer {
    static func jpegData(from raw: Data, maxDimension: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: raw) else { return nil }
        let size = image.size
        let longest = max(size.width, size.height)
        if longest <= maxDimension {
            return image.jpegData(compressionQuality: 0.8)
        }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
