//
//  MediaItem.swift
//  BananaTransfer
//
//  Wrapper attorno a un ICCameraFile: espone i dati che servono alla UI
//  (nome, data, thumbnail, stato di selezione/copia) come proprietà
//  osservabili, così SwiftUI aggiorna solo la cella interessata invece
//  di ridisegnare l'intera griglia ad ogni cambiamento.
//

import Foundation
import Combine
import ImageCaptureCore
import AppKit

enum MediaKind {
    case photo
    case video
    case raw
    case other
}

enum TransferState: Equatable {
    case idle
    case queued
    case copying(progress: Double)
    case verifying
    case done
    case failed(String)
    case skipped
}

final class MediaItem: ObservableObject, Identifiable {

    let id = UUID()

    /// Riferimento all'oggetto reale di ImageCaptureCore. Manteniamo un
    /// riferimento forte perché l'SDK invalida gli item se non sono
    /// referenziati da nessuna parte.
    let cameraItem: ICCameraFile

    let name: String
    let captureDate: Date?
    let kind: MediaKind
    let fileSizeBytes: Int64

    @Published var thumbnail: NSImage?
    @Published var isSelected: Bool = true
    @Published var transferState: TransferState = .idle

    init(cameraItem: ICCameraFile) {
        self.cameraItem = cameraItem
        self.name = cameraItem.name ?? "Senza nome"
        self.captureDate = cameraItem.creationDate
        self.fileSizeBytes = cameraItem.fileSize
        self.kind = MediaItem.kind(forUTI: cameraItem.uti, name: cameraItem.name)
        // La thumbnail viene popolata in modo asincrono dal delegate
        // cameraDevice(_:didReceiveThumbnail:for:error:) in DeviceManager.
    }

    private static func kind(forUTI uti: String?, name: String?) -> MediaKind {
        let ext = (name as NSString?)?.pathExtension.lowercased() ?? ""
        let videoExt: Set<String> = ["mov", "mp4", "m4v"]
        let photoExt: Set<String> = ["jpg", "jpeg", "heic", "png"]
        let rawExt: Set<String> = ["raw", "cr2", "cr3", "arw", "nef", "dng", "tiff", "tif"]
        if videoExt.contains(ext) { return .video }
        if photoExt.contains(ext) { return .photo }
        if rawExt.contains(ext) { return .raw }
        if let uti = uti?.lowercased() {
            if uti.contains("movie") || uti.contains("video") { return .video }
            if uti.contains("image") { return .photo }
            if uti.contains("raw") { return .raw }
        }
        return .other
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}
