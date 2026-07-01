//
//  Item.swift
//  MileLog
//
//  Created by Robert LIPIC on 13. 6. 2026.
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
