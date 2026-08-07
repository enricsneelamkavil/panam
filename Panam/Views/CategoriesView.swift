//
//  CategoriesView.swift
//  Panam
//

import SwiftUI
import SwiftData

/// Manage expense categories: add, rename, and remove.
/// Pushed from TransactionsView, so it doesn't create its own NavigationStack.
struct CategoriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.name) private var categories: [Category]
    @Query private var transactions: [Transaction]

    @State private var showingAddSheet = false
    @State private var categoryToEdit: Category?
    @State private var categoryPendingDeletion: Category?

    private static let otherGroupName = "Other"

    private struct CategoryGroup: Identifiable {
        let name: String
        let categories: [Category]
        var id: String { name }
    }

    /// Categories grouped by groupName for display — alphabetical group
    /// headers, ungrouped categories collected under "Other" at the bottom,
    /// alphabetical by name within each group. Purely a display/sort
    /// grouping; doesn't affect any aggregation logic elsewhere.
    private var groupedCategories: [CategoryGroup] {
        var groups: [String: [Category]] = [:]
        for category in categories {
            let trimmed = category.groupName?.trimmingCharacters(in: .whitespaces) ?? ""
            let groupName = trimmed.isEmpty ? Self.otherGroupName : trimmed
            groups[groupName, default: []].append(category)
        }

        var namedGroupNames = groups.keys.filter { $0 != Self.otherGroupName }
        namedGroupNames.sort()

        var result: [CategoryGroup] = []
        for name in namedGroupNames {
            let sorted = (groups[name] ?? []).sorted { $0.name < $1.name }
            result.append(CategoryGroup(name: name, categories: sorted))
        }
        if let other = groups[Self.otherGroupName], !other.isEmpty {
            result.append(CategoryGroup(name: Self.otherGroupName, categories: other.sorted { $0.name < $1.name }))
        }
        return result
    }

    var body: some View {
        List {
            categoryGroupSections
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Category", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddEditCategoryView()
        }
        .sheet(item: $categoryToEdit) { category in
            AddEditCategoryView(category: category)
        }
        .alert(
            "Category In Use",
            isPresented: Binding(
                get: { categoryPendingDeletion != nil },
                set: { if !$0 { categoryPendingDeletion = nil } }
            ),
            presenting: categoryPendingDeletion
        ) { category in
            Button("Delete", role: .destructive) {
                modelContext.delete(category)
            }
            Button("Cancel", role: .cancel) {}
        } message: { category in
            Text("\(category.name) is used by \(usageCount(of: category)) transaction\(usageCount(of: category) == 1 ? "" : "s"). Items using it will become uncategorized; the transactions themselves are kept.")
        }
    }

    @ViewBuilder
    private var categoryGroupSections: some View {
        ForEach(groupedCategories) { group in
            Section(group.name) {
                ForEach(group.categories) { category in
                    CategoryRow(category: category)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            categoryToEdit = category
                        }
                }
                .onDelete { offsets in
                    deleteCategories(at: offsets, from: group.categories)
                }
            }
        }
    }

    private func usageCount(of category: Category) -> Int {
        transactions.filter { $0.category === category }.count
    }

    private func deleteCategories(at offsets: IndexSet, from groupCategories: [Category]) {
        for index in offsets {
            let category = groupCategories[index]
            if usageCount(of: category) == 0 {
                modelContext.delete(category)
            } else {
                // In use — confirm before leaving items uncategorized.
                categoryPendingDeletion = category
            }
        }
    }
}

private struct CategoryRow: View {
    let category: Category

    var body: some View {
        HStack {
            Circle()
                .fill(DashboardView.color(for: category))
                .frame(width: 10, height: 10)
            Image(systemName: category.icon)
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(category.name)
            Spacer()
            if category.isPreset {
                Text("Preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AddEditCategoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The category being edited, or nil when creating a new one.
    var category: Category?

    @Query private var categories: [Category]

    @State private var name = ""
    @State private var icon = "circle.fill"
    @State private var showingIconPicker = false
    @State private var groupName = ""
    @State private var useCustomColor = false
    @State private var selectedColor: Color = .blue

    private var isEditing: Bool { category != nil }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Block duplicate names — several features look categories up by name.
        return !categories.contains {
            $0 !== category && $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }

                Section("Icon") {
                    Button {
                        showingIconPicker = true
                    } label: {
                        HStack {
                            Image(systemName: icon)
                                .frame(width: 36, height: 36)
                                .background(
                                    Color.accentColor.opacity(0.2),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .foregroundStyle(Color.accentColor)
                            Text("Choose Icon")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    Toggle("Custom Color", isOn: $useCustomColor.animation())
                    if useCustomColor {
                        ColorPicker("Category Color", selection: $selectedColor, supportsOpacity: false)
                    }
                } footer: {
                    Text("Used for this category's dot in Top Categories and its segment in the Spend Bar. Leave off to use the automatically assigned color.")
                }

                Section {
                    TextField("Group (optional)", text: $groupName)
                } footer: {
                    Text("Categories are grouped and sorted by this in the Categories list. Leave blank to show under \"Other.\"")
                }
            }
            .navigationTitle(isEditing ? "Edit Category" : "New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingIconPicker) {
                IconPickerView(selectedIcon: $icon)
            }
            .onAppear {
                guard let category else { return }
                name = category.name
                icon = category.icon
                groupName = category.groupName ?? ""
                if let hex = category.colorHex, let customColor = Color(hex: hex) {
                    useCustomColor = true
                    selectedColor = customColor
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let trimmedGroup = groupName.trimmingCharacters(in: .whitespaces)
        let hex = useCustomColor ? selectedColor.hexString : nil

        if let category {
            category.name = trimmedName
            category.groupName = trimmedGroup.isEmpty ? nil : trimmedGroup
            category.colorHex = hex
            category.icon = icon
        } else {
            modelContext.insert(Category(
                name: trimmedName,
                icon: icon,
                groupName: trimmedGroup.isEmpty ? nil : trimmedGroup,
                colorHex: hex
            ))
        }
        dismiss()
    }
}

#Preview {
    NavigationStack {
        CategoriesView()
    }
    .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
