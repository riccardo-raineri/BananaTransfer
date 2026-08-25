//
//  TransferLogger.swift
//  BananaTransfer
//
//  Scrive un registro CSV persistente dentro la cartella di destinazione,
//  con una riga per ogni file processato: esito, dimensione, SHA-256 ed
//  eventuali errori. Il file si chiama sempre "BananaTransfer-log.csv" e
//  viene aperto in append, quindi accumula la storia di tutte le sessioni
//  di copia fatte verso quella cartella.
//

import Foundation

final class TransferLogger {

    private let fileHandle: FileHandle?
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init?(destinationFolder: URL) {
        let logURL = destinationFolder.appendingPathComponent("BananaTransfer-log.csv")
        let fm = FileManager.default

        if !fm.fileExists(atPath: logURL.path) {
            let header = "DataOra;NomeOriginale;NomeSalvato;Esito;DimensioneByte;SHA256;Dettagli\n"
            guard fm.createFile(atPath: logURL.path, contents: header.data(using: .utf8)) else {
                self.fileHandle = nil
                return
            }
        }

        self.fileHandle = FileHandle(forWritingAtPath: logURL.path)
        self.fileHandle?.seekToEndOfFile()
    }

    func log(originalName: String, savedName: String, status: String, sizeBytes: Int64?, sha256: String?, detail: String?) {
        let timestamp = dateFormatter.string(from: Date())
        let sizeString = sizeBytes.map(String.init) ?? ""
        let sha = sha256 ?? ""
        // Il ";" è il separatore CSV: lo togliamo dal testo libero per non
        // spezzare le colonne per errore.
        let originalEscaped = originalName.replacingOccurrences(of: ";", with: ",")
        let savedEscaped = savedName.replacingOccurrences(of: ";", with: ",")
        let detailEscaped = (detail ?? "").replacingOccurrences(of: ";", with: ",")

        let line = "\(timestamp);\(originalEscaped);\(savedEscaped);\(status);\(sizeString);\(sha);\(detailEscaped)\n"
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    func close() {
        try? fileHandle?.close()
    }
}
