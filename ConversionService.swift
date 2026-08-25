//
//  ConversionService.swift
//  BananaTransfer
//
//  Conversioni opzionali eseguite DOPO che un file è già stato copiato
//  sano e salvo sull'HDD: usa ImageIO (foto) e AVFoundation (video), due
//  framework Apple stabili e ben documentati — a differenza di
//  ImageCaptureCore, qui non ci aspettiamo sorprese sulle firme dei metodi.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

enum ConversionService {

    /// Converte un'immagine HEIC in JPEG nella stessa cartella e cancella
    /// l'originale HEIC. Ritorna il nuovo URL, oppure nil se la conversione
    /// non è riuscita (in quel caso l'originale HEIC resta intatto).
    static func convertHEICToJPEG(at url: URL, quality: CGFloat = 0.9) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let jpegURL = url.deletingPathExtension().appendingPathExtension("jpg")

        guard let destination = CGImageDestinationCreateWithURL(
            jpegURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: jpegURL)
            return nil
        }

        try? FileManager.default.removeItem(at: url)
        return jpegURL
    }

    /// Converte un video (tipicamente HEVC/.MOV) in H.264/.mp4 nella stessa
    /// cartella e cancella l'originale. Il completion viene chiamato sul
    /// thread principale con il nuovo URL, oppure nil se la conversione non
    /// è riuscita (l'originale resta intatto in quel caso).
    static func convertVideoToH264(at url: URL, completion: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: url)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let folder = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        // Nome temporaneo univoco per evitare collisioni durante l'export;
        // rinominiamo al nome definitivo solo a conversione riuscita.
        let tempOutputURL = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")

        exportSession.outputURL = tempOutputURL
        exportSession.outputFileType = .mp4

        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                guard exportSession.status == .completed else {
                    try? FileManager.default.removeItem(at: tempOutputURL)
                    completion(nil)
                    return
                }
                let finalURL = folder.appendingPathComponent(baseName).appendingPathExtension("mp4")
                do {
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: tempOutputURL, to: finalURL)
                    try? FileManager.default.removeItem(at: url)
                    completion(finalURL)
                } catch {
                    completion(nil)
                }
            }
        }
    }

    static func isHEIC(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "heic"
    }

    static func isVideo(_ url: URL) -> Bool {
        ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
    }
}
