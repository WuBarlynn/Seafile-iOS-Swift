import SwiftUI

struct SDocOutlineSheet: View {
    let items: [SDocOutlineItem]
    let onSelect: (SDocOutlineItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("No data", systemImage: "list.bullet.indent")
                    }
                } else {
                    List(items) { item in
                        Button {
                            onSelect(item)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Text(item.displayText)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(item.indentLevel) * 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
