import Foundation
import SwiftData

@Model
final class Category {
    var name: String
    var icon: String
    var isPreset: Bool

    init(name: String, icon: String = "circle.fill", isPreset: Bool = false) {
        self.name = name
        self.icon = icon
        self.isPreset = isPreset
    }
}
