//
//  IconPickerView.swift
//  Plush
//

import SwiftUI

/// Searchable SF Symbol grid for choosing a category icon.
struct IconPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedIcon: String

    @State private var searchText = ""

    private var filteredIcons: [IconOption] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return CategoryIcons.all }
        return CategoryIcons.all.filter { option in
            option.symbolName.lowercased().contains(query)
                || option.keywords.contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(filteredIcons, id: \.symbolName) { option in
                        iconTile(for: option)
                    }
                }
                .padding()

                if filteredIcons.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 40)
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search icons"
            )
            .navigationTitle("Choose Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func iconTile(for option: IconOption) -> some View {
        let isSelected = option.symbolName == selectedIcon
        return Button {
            selectedIcon = option.symbolName
            dismiss()
        } label: {
            Image(systemName: option.symbolName)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .offset(x: 4, y: -4)
                    }
                }
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.symbolName)
    }
}

#Preview {
    IconPickerView(selectedIcon: .constant("fork.knife"))
}
