 //
//  Color+App.swift
//  Panam
//

import SwiftUI

/// App color system: use these instead of raw colors for actions so intent
/// stays consistent regardless of system accent inheritance.
extension Color {
    /// Primary actions — Save, add, confirm.
    static let appPrimary = Color.blue
}

extension ShapeStyle where Self == Color {
    static var appPrimary: Color { .appPrimary }
}
