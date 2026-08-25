//
//  FileOrganizer.swift
//  BananaTransfer
//
//  Funzioni pure (facili da testare) per decidere in quale sottocartella
//  finisce ogni file e come evitare collisioni di nomi.
//

import Foundation

enum DateFolderStyle: String, CaseIterable, Identifiable {
    case dayFolder = "AAAA-MM-GG"       // 2026-08-22/
    case yearMonth = "AAAA/AAAA-MM"     // 2026/2026-08/

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dayFolder: return "Una cartella per giorno (2026-08-22)"
        case .yearMonth: return "Anno / Mese (2026/2026-08)"
        }
    }
}

enum DuplicatePolicy: String, CaseIterable, Identifiable {
    case skip = "Salta"
    case rename = "Rinomina"
    case overwrite = "Sovrascrivi"

    var id: String { rawValue }
}

enum MediaKindFilter: String, CaseIterable, Identifiable {
    case all = "Tutti"
    case photo = "Foto"
    case video = "Video"
    case raw = "RAW"

    var id: String { rawValue }
}

enum FileOrganizer {

    /// Calcola l'URL della cartella di destinazione per un file, in base
    /// alla data di scatto. Se la data non è disponibile, i file finiscono
    /// in una cartella "Senza-data" invece di essere persi o sovrascritti.
    static func destinationFolder(
        root: URL,
        captureDate: Date?,
        style: DateFolderStyle,
        calendar: Calendar = .current
    ) -> URL {
        guard let date = captureDate else {
            return root.appendingPathComponent("Senza-data")
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "it_IT")

        switch style {
        case .dayFolder:
            formatter.dateFormat = "yyyy-MM-dd"
            return root.appendingPathComponent(formatter.string(from: date))
        case .yearMonth:
            let yearFormatter = DateFormatter()
            yearFormatter.dateFormat = "yyyy"
            formatter.dateFormat = "yyyy-MM"
            let year = yearFormatter.string(from: date)
            let yearMonth = formatter.string(from: date)
            return root.appendingPathComponent(year).appendingPathComponent(yearMonth)
        }
    }

    /// Restituisce un nome file libero nella cartella indicata, aggiungendo
    /// " (2)", " (3)", ecc. se un file con lo stesso nome esiste già.
    /// Necessario perché più scatti da fotocamere diverse (o burst) possono
    /// generare nomi duplicati come "IMG_0001.HEIC".
    static func uniqueFileName(for originalName: String, in folder: URL, fileManager: FileManager = .default) -> String {
        let ext = (originalName as NSString).pathExtension
        let base = (originalName as NSString).deletingPathExtension

        var candidate = originalName
        var counter = 2
        while fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }
}
