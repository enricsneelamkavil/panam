import Foundation
import SwiftData

@Model
final class Category {
    var name: String
    var icon: String
    var isPreset: Bool
    /// Optional display/sort grouping for the Categories list (e.g. "Bills",
    /// "Lifestyle"). Purely cosmetic — doesn't affect any aggregation logic.
    var groupName: String?
    /// Optional custom color as a "#RRGGBB" hex string, used for this
    /// category's dot/segment in Top Categories and the Spend Bar. nil falls
    /// back to the auto-assigned palette color — see DashboardView.color(for:).
    var colorHex: String?

    init(name: String, icon: String = "circle.fill", isPreset: Bool = false,
         groupName: String? = nil, colorHex: String? = nil) {
        self.name = name
        self.icon = icon
        self.isPreset = isPreset
        self.groupName = groupName
        self.colorHex = colorHex
    }
}
