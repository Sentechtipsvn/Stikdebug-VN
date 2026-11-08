import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct LibraryRouteAction {
    let route: SavedSimulationRoute
    var deletesRoute = false
}

struct VNExportItem: Identifiable { let url: URL; var id: String { url.absoluteString } }

struct VNShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct RouteLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RouteLibraryStore.shared
    var confirmSelection = false
    let onSelect: (SavedSimulationRoute) -> Void
    @State private var showImport = false
    @State private var error: String?
    @State private var exported: VNExportItem?
    @State private var pendingAction: LibraryRouteAction?

    var body: some View {
        NavigationStack {
            List {
                if let error = store.loadError { Text(error).foregroundStyle(.red) }
                if store.routes.isEmpty {
                    ContentUnavailableView("Chưa lưu tuyến nào", systemImage: "point.topleft.down.curvedto.point.bottomright.up", description: Text("Tạo một tuyến rồi bấm Lưu tuyến để dùng lại."))
                }
                ForEach(store.routes) { route in
                    Button {
                        if confirmSelection { pendingAction = .init(route: route) }
                        else { select(route) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(route.name).font(.headline).foregroundStyle(.primary)
                            Text("\(route.waypoints.count) điểm · \(route.speedKmh.formatted()) km/h")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(route.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Xóa") { pendingAction = .init(route: route, deletesRoute: true) }.tint(.red)
                        Button("Xuất", systemImage: "square.and.arrow.up") {
                            do { exported = .init(url: try store.exportURL(for: route)) } catch { self.error = error.localizedDescription }
                        }.tint(.blue)
                    }
                    .contextMenu {
                        Button("Xuất JSON", systemImage: "square.and.arrow.up") {
                            do { exported = .init(url: try store.exportURL(for: route)) } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle("Tuyến đã lưu").navigationBarTitleDisplayMode(.inline).tint(.green)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Nhập JSON", systemImage: "square.and.arrow.down") { showImport = true } }
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
                do { try store.importFile(try result.get()) } catch { self.error = error.localizedDescription }
            }
            .sheet(item: $exported) { VNShareSheet(url: $0.url) }
            .alert(pendingAction?.deletesRoute == true ? "Xóa tuyến đã lưu?" : "Mở tuyến đã lưu?", isPresented: Binding(
                get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
            ), presenting: pendingAction) { action in
                if action.deletesRoute {
                    Button("Xóa tuyến", role: .destructive) {
                        do { try store.delete(action.route) } catch { self.error = error.localizedDescription }
                    }
                } else {
                    Button("Mở tuyến") { select(action.route) }
                }
                Button("Hủy", role: .cancel) {}
            } message: { action in
                Text(action.deletesRoute ? action.route.name : "Tuyến \(action.route.name) sẽ thay tuyến đang xem và bản nháp chưa áp dụng.")
            }
            .alert("Không thực hiện được", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Đóng", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func select(_ route: SavedSimulationRoute) {
        onSelect(route)
        dismiss()
    }
}
