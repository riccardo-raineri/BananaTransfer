//
//  FolderPickerService.swift
//  BananaTransfer
//
//  Apre l'NSOpenPanel per scegliere la cartella sull'HDD e ricorda la
//  scelta tra una sessione e l'altra tramite un security-scoped bookmark
//  (necessario se in futuro abiliti l'App Sandbox; è innocuo anche se il
//  sandbox è disattivato).
//

import AppKit
import Foundation

enum FolderPickerService {

    private static let bookmarkKey = "destinationFolderBookmark"

    /// Mostra il pannello di scelta cartella. Ritorna l'URL scelto oppure
    /// nil se l'utente ha annullato.
    static func chooseFolder(currentWindow: NSWindow?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Scegli la cartella di destinazione sull'HDD"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Usa questa cartella"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        saveBookmark(for: url)
        return url
    }

    /// All'avvio dell'app, prova a recuperare l'ultima cartella scelta.
    static func restoreLastFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            _ = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            // Il bookmark salvato non è più valido (es. l'HDD è stato
            // rinominato o riformattato): l'utente dovrà semplicemente
            // riselezionare la cartella, non è un errore bloccante.
            return nil
        }
    }

    private static func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            // Se il salvataggio del bookmark fallisce (es. sandbox
            // disattivato, che non richiede security scope) non è grave:
            // la cartella scelta ora funziona comunque per questa sessione.
        }
    }
}
