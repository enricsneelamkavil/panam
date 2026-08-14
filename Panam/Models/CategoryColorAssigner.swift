import SwiftUI
import UIKit

/// Assigns every category a guaranteed-unique color for the app session —
/// replaces the old per-name hash lookup (DashboardView.color(for:)
/// pre-this-file), which picked an index via `hash(name) % paletteCount`
/// and could put two different categories on the exact same color once
/// there were more categories than base colors (routine: CategorySeeder
/// alone seeds 21 presets against a 12-color palette).
///
/// Built once per session (not persisted — a fresh shuffle every launch,
/// same as the old lookup's "assigned once per session" framing) from
/// DashboardView.barPalette, shuffled, and grown with saturation/brightness
/// variants of those same base hues if there are more categories than base
/// colors. Growth only ever appends — an existing category's assigned
/// index/color never changes just because a new category needed the
/// palette extended, so colors stay stable as you add categories mid-session.
enum CategoryColorAssigner {
    private static var assignments: [UUID: Color] = [:]
    private static var palette: [Color] = []
    private static var nextRound = 1

    static func color(for category: Category, among allCategories: [Category]) -> Color {
        ensureAssigned(allCategories)
        return assignments[category.backupID] ?? DashboardView.barPalette[0]
    }

    private static func ensureAssigned(_ categories: [Category]) {
        let unassigned = categories.filter { assignments[$0.backupID] == nil }
        guard !unassigned.isEmpty else { return }

        growPalette(toAtLeast: assignments.count + unassigned.count)

        var nextIndex = assignments.count
        for category in unassigned {
            assignments[category.backupID] = palette[nextIndex % palette.count]
            nextIndex += 1
        }
    }

    /// Append-only: never reshuffles or replaces colors already handed out
    /// at existing indices, only adds more at the end when needed.
    private static func growPalette(toAtLeast minimumCount: Int) {
        if palette.isEmpty {
            palette = DashboardView.barPalette.shuffled()
        }
        while palette.count < minimumCount {
            let variants = DashboardView.barPalette
                .map { variant(of: $0, round: nextRound) }
                .shuffled()
            palette.append(contentsOf: variants)
            nextRound += 1
        }
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
