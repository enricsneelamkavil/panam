//
//  MaskableCurrencyText.swift
//  Plush
//

import SwiftUI

/// Currency text that renders as dots when the privacy mask (the dashboard's
/// eye toggle) is on.
struct MaskableCurrencyText: View {
    static let maskKey = "amountsMasked"

    let amount: Double
    var font: Font = .body

    @AppStorage(Self.maskKey) private var masked = false

    var body: some View {
        Group {
            if masked {
                Text("₹••••••")
            } else {
                Text(amount, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
            }
        }
        .font(font)
    }
}
