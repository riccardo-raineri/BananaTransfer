//
//  TransferVerifier.swift
//  BananaTransfer
//
//  Verifica l'integrità di ogni file appena copiato: controllo dimensione
//  (obbligatorio, intercetta trasferimenti troncati) e calcolo SHA-256
//  (per il registro delle operazioni). Legge in blocchi da 4MB per non
//  caricare interi video in memoria.
//

import Foundation
import CryptoKit

enum TransferVerifier {

    enum VerificationResult {
        case success(sha256: String)
        case failure(String)
    }

    static func verify(localURL: URL, expectedSizeBytes: Int64) -> VerificationResult {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
              let sizeNumber = attrs[.size] as? NSNumber else {
            return .failure("Impossibile leggere il file appena copiato")
        }

        let actualSize = sizeNumber.int64Value
        if expectedSizeBytes > 0 && actualSize != expectedSizeBytes {
            return .failure("Dimensione non corrispondente (attesi \(expectedSizeBytes) byte, trovati \(actualSize)): possibile trasferimento incompleto")
        }

        guard let handle = FileHandle(forReadingAtPath: localURL.path) else {
            return .failure("Impossibile aprire il file per il controllo di integrità")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return .success(sha256: hex)
    }
}
