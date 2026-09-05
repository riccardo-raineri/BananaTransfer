//
//  LibraryScanner.swift
//  BananaTransfer
//
//  Scansiona ricorsivamente una cartella (tipicamente quella dove sono
//  già stati salvati trasferimenti precedenti) per costruire un indice
//  veloce di "cosa c'è già", da confrontare con gli elementi sull'iPhone
//  prima di avviare una nuova copia — evita di ritrasferire foto/video già
//  presenti, anche se sono state spostate/riorganizzate rispetto alla
//  struttura per data che avrebbe usato l'ultima sessione di copia.
//
//  L'impronta usata è "nome file (minuscolo) + dimensione in byte": è
//  molto più veloce di calcolare un hash su un'intera libreria (che può
//  essere centinaia di GB), e per foto/video già di per sé nominati in
//  modo pressoché univoco da iOS (IMG_XXXX) è un confronto affidabile.
//

import Foundation

enum LibraryScanner {

    /// Costruisce l'insieme delle impronte "nome|dimensione" di tutti i
    /// file trovati ricorsivamente dentro root. Salta i file che non
    /// sembrano foto/video (incluso il nostro stesso file di log CSV).
    static func scanFingerprints(root: URL) -> Set<String> {
        var fingerprints: Set<String> = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return fingerprints
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }

            fingerprints.insert(fingerprint(name: fileURL.lastPathComponent, sizeBytes: Int64(size)))
        }

        return fingerprints
    }

    static func fingerprint(name: String, sizeBytes: Int64) -> String {
        "\(name.lowercased())|\(sizeBytes)"
    }
}
