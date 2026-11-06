import SwiftUI

struct RestDurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pointName: String
    let onSave: (Double) -> Void
    @State private var text: String
    @State private var unit: RestDurationUnit
    @FocusState private var focused: Bool

    init(seconds: Double, pointName: String, onSave: @escaping (Double) -> Void) {
        self.pointName = pointName
        self.onSave = onSave
        let value = RestDuration.initialEntry(seconds: seconds)
        _text = State(initialValue: value.0)
        _unit = State(initialValue: value.1)
    }

    private var parsed: Double? { try? RestDuration.parse(text, unit: unit) }

    var body: some View {
        NavigationStack {
            Form {
                Section(pointName) {
                    TextField("Nhập thời gian", text: $text).keyboardType(.decimalPad).focused($focused)
                        .font(.title2.monospacedDigit()).accessibilityIdentifier("rest.duration.input")
                    Picker("Đơn vị", selection: $unit) {
                        ForEach(RestDurationUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if let parsed {
                        Text(parsed == 0 ? "Đi qua điểm này, không nghỉ." : "Nghỉ \(RestDuration.clock(parsed)), sau đó tự đi tiếp.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Nhập số hợp lệ từ 0 giây đến 24 giờ. Ví dụ 5 phút hoặc 1,5 phút.").font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    Text("Thời gian bắt đầu khi đến trạm. Tạm dừng bằng tay sẽ giữ nguyên phần thời gian còn lại.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Thời gian nghỉ").navigationBarTitleDisplayMode(.inline).tint(.green)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") { if let parsed { onSave(parsed); dismiss() } }.disabled(parsed == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
