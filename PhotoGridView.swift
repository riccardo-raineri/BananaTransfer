//
//  PhotoGridView.swift
//  BananaTransfer
//

import SwiftUI
import AppKit

struct PhotoGridView: View {

    @EnvironmentObject var manager: DeviceManager
    @State private var lastSelectedIndex: Int? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)
    ]

    var body: some View {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    let items = manager.filteredMediaItems
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PhotoThumbnailView(item: item)
                            .onTapGesture {
                                handleTap(at: index, in: items)
                            }
                    }
                }
                .padding()
            }
        }

        private func handleTap(at index: Int, in items: [MediaItem]) {
            let isShiftPressed = NSEvent.modifierFlags.contains(.shift)

            if isShiftPressed, let lastIndex = lastSelectedIndex, items.indices.contains(lastIndex) {
                let start = min(lastIndex, index)
                let end = max(lastIndex, index)

                for i in start...end {
                    items[i].isSelected = true
                }
            } else {
                items[index].isSelected.toggle()
                lastSelectedIndex = index
            }
        }
    }
