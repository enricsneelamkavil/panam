//
//  MaskableCurrency.swift
//  Plush
//

import SwiftUI

/// ₹-formatted text that renders as a fixed placeholder while the privacy
/// toggle (PrivacyState) hides amounts. Font/color modifiers applied by the
/// caller flow through, so it drops in wherever a currency Text lived.
struct MaskableCurrencyText: View {
    // Optional so previews without an injected PrivacyState don't crash —
    // no state means amounts show normally.
    @Environment(PrivacyState.self) private var privacyState: PrivacyState?

    let amount: Double

    var body: some View {
        if privacyState?.amountsHidden == true {
            Text("••••••")
                .monospaced()
        } else {
            Text(amount, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
        }
    }
}
