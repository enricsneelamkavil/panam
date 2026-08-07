 //
//  Color+App.swift
//  Panam
//

import SwiftUI
import UIKit

/// App color system: use these instead of raw colors for actions so intent
/// stays consistent regardless of system accent inheritance.
extension Color {
    /// Primary actions — Save, add, confirm.
    static let appPrimary = Color.blue
}

extension Color {
    /// Creates a Color from a "#RRGGBB" (or "RRGGBB") hex string. Returns
    /// nil for anything malformed, so callers can fall back cleanly.
    init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        guard hexString.count == 6, let value = UInt32(hexString, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    /// This color as a "#RRGGBB" hex string, in the sRGB color space.
    var hexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X",
                      Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

extension ShapeStyle where Self == Color {
    static var appPrimary: Color { .appPrimary }
}
