//
//  Item.swift
//  Plush
//
//  Created by Enric Shajan Neelamkavil(UST,IN) on 18/07/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
