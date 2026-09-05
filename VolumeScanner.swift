//
//  VolumeScanner.swift
//  BananaTransfer
//
//  Scansiona ricorsivamente un volume USB/SD (montato come disco normale,
//  non via ImageCaptureCore) per trovare foto e video, restituendo dei
//  MediaItem pronti da mostrare in griglia — stesso modello dati usato
//  per i file letti dalla fotocamera, così il resto dell'app (selezione,
//  filtro, copia, verifica) funziona identico indipendentemente dalla
//  provenienza.
//

import Foundation

enum VolumeScanner {

    static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "png",
        "mov", "mp4", "m4v",
        "raw", "cr2", "cr3", "arw", "nef", "dng", "tiff", "tif"
    ]

    static func scanMedia(root: URL) -> [MediaItem] {
        var results: [MediaItem] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }

            let ext = fileURL.pathExtension.lowercased()
            guard mediaExtensions.contains(ext) else { continue }

            results.append(MediaItem(localFileURL: fileURL))
        }

        return results
    }
}
