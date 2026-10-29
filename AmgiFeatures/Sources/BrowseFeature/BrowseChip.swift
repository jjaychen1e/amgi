//
//  BrowseChip.swift
//  BrowseFeature
//
//  Created by Junjie Chen on 29.10.2026.
//

import SwiftUI
import Theme

/// The capsule chip behind Browse's deck and tag filters, and the card
/// previewer's pick of which of a note's cards to show.
struct BrowseChip: View {
    @Environment(\.palette) private var palette
    let label: String
    let isSelected: Bool
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .amgiFont(small ? .caption : .body)
                .padding(.horizontal, small ? 10 : 12)
                .padding(.vertical, small ? 4 : 6)
                .background(isSelected ? palette.accent : palette.surface)
                .foregroundStyle(isSelected ? .white : palette.textPrimary)
                .clipShape(Capsule())
        }
        .buttonStyle(.pressScale)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
