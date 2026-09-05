//
//  PhotoThumbnailView.swift
//  BananaTransfer
//

import SwiftUI

struct PhotoThumbnailView: View {

    @ObservedObject var item: MediaItem
    @EnvironmentObject var manager: DeviceManager

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnailImage
                    .frame(width: 150, height: 150)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(item.isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    )
                    .opacity(item.isAlreadyInLibrary ? 0.5 : 1)
                    .onAppear {
                        manager.loadThumbnailIfNeeded(for: item)
                    }

                selectionBadge
                    .padding(6)

                if item.isAlreadyInLibrary {
                    Text("Già presente")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.orange, in: Capsule())
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                if item.kind == .video {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.5), in: Circle())
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                statusOverlay
            }

            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)

            if let date = item.captureDate {
                Text(date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbnail = item.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ProgressView()
        }
    }

    private var selectionBadge: some View {
        Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundStyle(item.isSelected ? Color.accentColor : .white, .black.opacity(0.35))
            .symbolRenderingMode(.palette)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch item.transferState {
        case .idle, .queued:
            EmptyView()
        case .copying(let progress):
            VStack {
                Spacer()
                ProgressView(value: progress)
                    .padding(6)
            }
        case .verifying:
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Verifica…").font(.system(size: 9))
                }
                .padding(4)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .bottom)
        case .done:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.white, .green)
                .symbolRenderingMode(.palette)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white, .red)
                .symbolRenderingMode(.palette)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        case .skipped:
            Image(systemName: "arrow.uturn.forward.circle.fill")
                .foregroundStyle(.white, .gray)
                .symbolRenderingMode(.palette)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}
