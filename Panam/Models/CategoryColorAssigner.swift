import SwiftUI
import UIKit

/// Assigns every category a persistent color, stored on the category
/// itself (`Category.colorIndex`) instead of rebuilt fresh every session —
/// replaces the old in-memory `[UUID: Color]` dictionary, which was
/// reshuffled from `DashboardView.barPalette.shuffled()` on every app
/// launch, so a category's color changed every time you reopened the app.
///
/// Two pieces of persisted state work together:
///  - `Category.colorIndex` — assigned once, the first time a category's
///    color is ever resolved (covers both a brand-new category and any
///    pre-existing category from before this field existed, which starts
///    at the model's -1 sentinel until then), and never reassigned again —
///    see Category.colorIndex's own doc comment.
///  - `paletteOrder` (UserDefaults-backed) — a permutation of
///    `DashboardView.barPalette`'s indices, shuffled once ever so
///    colorIndex 0, 1, 2… still land on visually varied colors rather than
///    the palette's own declared order, and cached for the process
///    lifetime once loaded/generated. Without this, every user's category
///    #0 would be the same blue, #1 the same green, etc.
enum CategoryColorAssigner {
    private static let paletteOrderKey = "categoryColorPaletteOrder"
    private static var cachedPaletteOrder: [Int]?

    /// Resolves `category`'s persistent color, assigning it a colorIndex
    /// first if this is the first time it's ever been resolved.
    /// `allCategories` only matters for that one-time assignment — it's
    /// how "next unused index" is computed — so an already-assigned
    /// category never actually needs it.
    static func color(for category: Category, among allCategories: [Category]) -> Color {
        if category.colorIndex < 0 {
            category.colorIndex = nextColorIndex(among: allCategories)
        }
        return paletteColor(at: category.colorIndex)
    }

    /// One past the highest colorIndex already handed out. Never reuses a
    /// gap left by a deleted category — always grows — so an index, once
    /// assigned, uniquely identified that one category's color for as long
    /// as any other category's colorIndex might have been computed relative
    /// to it.
    private static func nextColorIndex(among categories: [Category]) -> Int {
        (categories.map(\.colorIndex).max() ?? -1) + 1
    }

    /// Maps a colorIndex to an actual color: cycles through `paletteOrder`
    /// for the first pass through the base palette, then a deterministic
    /// lighter/darker variant of the same base hues for indices beyond
    /// that (round 2 = first set of variants, round 3 = a second, further
    /// set, etc.) — same growth scheme the old session-only version used,
    /// just computed purely from `index` now instead of grown
    /// incrementally into a cached array, so it needs nothing beyond the
    /// index itself to always land on the same color.
    private static func paletteColor(at index: Int) -> Color {
        let order = paletteOrder()
        guard !order.isEmpty else { return DashboardView.barPalette.first ?? .gray }
        let position = index % order.count
        let round = index / order.count
        let base = DashboardView.barPalette[order[position]]
        return round == 0 ? base : variant(of: base, round: round)
    }

    /// The base palette's indices in shuffled order — generated once
    /// (whichever launch happens to be the first time any category's color
    /// is resolved) and persisted from then on, so colorIndex → color
    /// stays fixed forever after, the same way colorIndex itself does.
    private static func paletteOrder() -> [Int] {
        if let cachedPaletteOrder { return cachedPaletteOrder }
        let baseCount = DashboardView.barPalette.count
        let order: [Int]
        if let stored = UserDefaults.standard.array(forKey: paletteOrderKey) as? [Int],
           stored.count == baseCount, Set(stored) == Set(0..<baseCount) {
            order = stored
        } else {
            order = Array(0..<baseCount).shuffled()
            UserDefaults.standard.set(order, forKey: paletteOrderKey)
        }
        cachedPaletteOrder = order
        return order
    }

    /// A lighter or darker, slightly more saturated version of `color`,
    /// stepping further from the original with each successive `round` so
    /// round 2's variants stay distinguishable from round 3's, etc.
    /// Alternates lighter/darker per round rather than only ever darkening
    /// (which would eventually crush everything toward black).
    private static func variant(of color: Color, round: Int) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let step = 0.18 * Double(round)
        let adjustedBrightness = round.isMultiple(of: 2)
            ? max(0.3, Double(brightness) - step)
            : min(1.0, Double(brightness) + step)
        let adjustedSaturation = min(1.0, Double(saturation) + 0.12 * Double(round))

        return Color(hue: Double(hue), saturation: adjustedSaturation, brightness: adjustedBrightness)
    }
}
