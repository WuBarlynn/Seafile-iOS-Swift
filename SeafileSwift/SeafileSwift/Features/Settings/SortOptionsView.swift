import SwiftUI

struct SortOptionsView: View {
    @Binding var selection: DirentSortKey
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(DirentSortKey.allCases) { key in
                            Button {
                                selection = key
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Label(LocalizedStringKey(key.title), systemImage: key.symbol)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    if selection == key {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.seafileOrange)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .glassCard(cornerRadius: 20, padding: 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Sort by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
