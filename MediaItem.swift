//
//  MediaItem.swift
//  BananaTransfer
//
//  Wrapper attorno a un file multimediale, che può provenire da due
//  origini diverse: una fotocamera/iPhone via ImageCaptureCore (ICCameraFile)
//  oppure un file già presente localmente su un volume USB/SD montato come
//  disco normale. Espone dati e stato (nome, data, thumbnail, selezione,
//  avanzamento) come proprietà osservabili, così SwiftUI aggiorna solo la
//  cella interessata invece di ridisegnare l'intera griglia.
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

/// Da dove viene davvero questo file: una fotocamera collegata via cavo
/// (letta con ImageCaptureCore) oppure un file già presente su un volume
/// USB/SD montato come disco (letto con FileManager, come un file locale
/// qualunque).
enum MediaOrigin {
    case camera(ICCameraFile)
    case localFile(URL)
}

final class MediaItem: ObservableObject, Identifiable {

    let id = UUID()

    let origin: MediaOrigin

    let name: String
    let captureDate: Date?
    let kind: MediaKind
    let fileSizeBytes: Int64

    @Published var thumbnail: NSImage?
    @Published var isSelected: Bool = true
    @Published var transferState: TransferState = .idle
    /// true se una scansione di una cartella esistente (vedi
    /// LibraryScanner) ha trovato un file con nome e dimensione uguali:
    /// probabile segno che questo elemento è già stato trasferito in
    /// passato, anche in un'altra sessione dell'app.
    @Published var isAlreadyInLibrary: Bool = false

    /// Chiave stabile e univoca per questo elemento, usata al posto di
    /// ObjectIdentifier (che funziona solo per riferimenti a classi come
    /// ICCameraFile, non per gli URL dei file locali) nei dizionari interni
    /// del DeviceManager: così lo stesso codice di coda/download funziona
    /// per entrambe le origini.
    var sourceKey: AnyHashable {
        switch origin {
        case .camera(let file):
            return AnyHashable(ObjectIdentifier(file))
        case .localFile(let url):
            return AnyHashable(url.path)
        }
    }

    /// Inizializzatore per un file letto da una fotocamera/iPhone via
    /// ImageCaptureCore.
    init(cameraItem: ICCameraFile) {
        self.origin = .camera(cameraItem)
        self.name = cameraItem.name ?? "Senza nome"
        self.captureDate = cameraItem.creationDate
        self.fileSizeBytes = cameraItem.fileSize
        self.kind = MediaItem.kind(forUTI: cameraItem.uti, name: cameraItem.name)
    }

    /// Inizializzatore per un file già presente su un volume USB/SD montato
    /// come disco normale: qui non c'è nessun oggetto ImageCaptureCore,
    /// leggiamo tutto con FileManager/URL come per un file locale qualsiasi.
    init(localFileURL: URL) {
        self.origin = .localFile(localFileURL)
        self.name = localFileURL.lastPathComponent
        let values = try? localFileURL.resourceValues(forKeys: [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey
        ])
        self.fileSizeBytes = Int64(values?.fileSize ?? 0)
        // La data di creazione del file è la stima migliore disponibile
        // per la "data di scatto" su un volume esterno; se manca, usiamo
        // la data di modifica come ripiego.
        self.captureDate = values?.creationDate ?? values?.contentModificationDate
        self.kind = MediaItem.kind(forUTI: nil, name: localFileURL.lastPathComponent)
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
