import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VNExportItem: Identifiable { let url: URL; var id: String { url.absoluteString } }

struct VNShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct RouteLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RouteLibraryStore.shared
    let onSelect: (SavedSimulationRoute) -> Void
    @State private var showImport = false
    @State private var error: String?
    @State private var exported: VNExportItem?

    var body: some View {
        NavigationStack {
            List {
                if let error = store.loadError { Text(error).foregroundStyle(.red) }
                if store.routes.isEmpty {
                    ContentUnavailableView("Chưa lưu tuyến nào", systemImage: "point.topleft.down.curvedto.point.bottomright.up", description: Text("Tạo một tuyến rồi bấm Lưu tuyến để dùng lại."))
                }
                ForEach(store.routes) { route in
                    Button {
                        onSelect(route)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(route.name).font(.headline).foregroundStyle(.primary)
                            Text("\(route.waypoints.count) điểm · \(route.speedKmh.formatted()) km/h")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(route.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Xóa", role: .destructive) { do { try store.delete(route) } catch { self.error = error.localizedDescription } }
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
            .alert("Không thực hiện được", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Đóng", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
