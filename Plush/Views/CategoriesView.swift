//
//  CategoriesView.swift
//  Plush
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

    var body: some View {
        List {
            ForEach(categories) { category in
                HStack {
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
                .contentShape(Rectangle())
                .onTapGesture {
                    categoryToEdit = category
                }
            }
            .onDelete(perform: deleteCategories)
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Category", systemImage: "plus")
                }
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

    private func usageCount(of category: Category) -> Int {
        transactions.filter { $0.category === category }.count
    }

    private func deleteCategories(at offsets: IndexSet) {
        for index in offsets {
            let category = categories[index]
            if usageCount(of: category) == 0 {
                modelContext.delete(category)
            } else {
                // In use — confirm before leaving items uncategorized.
                categoryPendingDeletion = category
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
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let category {
            category.name = trimmedName
            category.icon = icon
        } else {
            modelContext.insert(Category(name: trimmedName, icon: icon))
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
