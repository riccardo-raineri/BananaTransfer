//
//  DeviceManager.swift
//  BananaTransfer
//
//  Cuore dell'app. Usa ImageCaptureCore per rilevare l'iPhone, leggere
//  foto/video e scaricarli sull'HDD con: filtro Foto/Video, gestione
//  duplicati (salta/rinomina/sovrascrivi), pausa/ripresa, annullamento,
//  download paralleli, verifica di integrità (dimensione + SHA-256) dopo
//  ogni copia, registro CSV delle operazioni, riepilogo finale e retry
//  dei falliti. Conversioni opzionali HEIC→JPEG / HEVC→H.264 dopo verifica.
//
//  NOTA SU QUESTO FILE
//  ImageCaptureCore è un framework Objective-C con documentazione ufficiale
//  scarsa; le firme dei metodi delegate usati qui sotto sono state
//  verificate direttamente sull'interfaccia generata da Xcode per l'SDK
//  installato (Cmd+clic sui nomi dei protocolli per ricontrollarle in caso
//  di aggiornamenti futuri di macOS).
//

import Foundation
import ImageCaptureCore
import AppKit
import Combine

struct TransferSummary {
    let copied: Int
    let skipped: Int
    let failed: Int

    var message: String {
        var parts: [String] = ["\(copied) copiati"]
        if skipped > 0 { parts.append("\(skipped) saltati (già presenti)") }
        if failed > 0 { parts.append("\(failed) falliti") }
        return parts.joined(separator: ", ")
    }
}

@objc final class DeviceManager: NSObject, ObservableObject {

    // MARK: - Stato pubblicato verso la UI

    @Published var isDeviceConnected = false
    @Published var deviceName: String = ""
    @Published var isCatalogReady = false
    @Published var mediaItems: [MediaItem] = []
    @Published var statusMessage: String = "In attesa di un iPhone collegato via cavo…"

    @Published var destinationFolder: URL?
    @Published var dateFolderStyle: DateFolderStyle = .dayFolder
    @Published var organizeByDate: Bool = true
    @Published var duplicatePolicy: DuplicatePolicy = .rename
    @Published var kindFilter: MediaKindFilter = .all

    @Published var convertHEICtoJPEG: Bool = false
    @Published var convertVideoToH264: Bool = false
    @Published var deleteFromDeviceAfterCopy: Bool = false

    @Published var isCopying = false
    @Published var isPaused = false
    @Published var totalToCopy = 0
    @Published var copiedSoFar = 0
    @Published var lastError: String?
    @Published var transferSummary: TransferSummary?

    var filteredMediaItems: [MediaItem] {
        switch kindFilter {
        case .all: return mediaItems
        case .photo: return mediaItems.filter { $0.kind == .photo }
        case .video: return mediaItems.filter { $0.kind == .video }
        case .raw: return mediaItems.filter { $0.kind == .raw }
        }
    }

    var hasFailedItems: Bool {
        mediaItems.contains { if case .failed = $0.transferState { return true }; return false }
    }

    // MARK: - Stato interno

    private let deviceBrowser = ICDeviceBrowser()
    private var cameraDevice: ICCameraDevice?
    private var mediaItemsByObjectID: [ObjectIdentifier: MediaItem] = [:]
    private var requestedThumbnails: Set<ObjectIdentifier> = []

    /// Quanti download tenere attivi in parallelo. La verifica di
    /// integrità (dimensione + SHA-256) occupa lo slot fino al termine,
    /// quindi questo numero limita anche quante verifiche girano insieme.
    private let maxConcurrentDownloads = 3

    private var downloadQueue: [MediaItem] = []
    private var activeDownloads: [ObjectIdentifier: MediaItem] = [:]
    private var itemsCompletedThisSession: [MediaItem] = []
    private var sessionItems: [MediaItem] = []
    private var logger: TransferLogger?

    // MARK: - Ciclo di vita

    override init() {
        super.init()
        destinationFolder = FolderPickerService.restoreLastFolder()

        deviceBrowser.delegate = self
        deviceBrowser.browsedDeviceTypeMask = .camera
        deviceBrowser.start()
    }

    deinit {
        deviceBrowser.stop()
    }

    // MARK: - Azioni richiamate dalla UI

    func chooseDestinationFolder(window: NSWindow?) {
        if let url = FolderPickerService.chooseFolder(currentWindow: window) {
            destinationFolder = url
        }
    }

    func toggleSelectAll(_ selected: Bool) {
        // Agisce solo sugli elementi attualmente visibili col filtro
        // Foto/Video attivo: più intuitivo che selezionare anche quelli nascosti.
        for item in filteredMediaItems { item.isSelected = selected }
    }

    func loadThumbnailIfNeeded(for item: MediaItem) {
        guard item.thumbnail == nil else { return }
        let key = ObjectIdentifier(item.cameraItem)
        guard !requestedThumbnails.contains(key) else { return }
        requestedThumbnails.insert(key)

        item.cameraItem.requestThumbnailData(options: nil) { data, error in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                item.thumbnail = image
            }
        }
    }

    func startCopySelected() {
        guard let root = destinationFolder else {
            lastError = "Scegli prima una cartella di destinazione sull'HDD."
            return
        }
        guard cameraDevice != nil else {
            lastError = "Nessun iPhone collegato."
            return
        }

        let selected = mediaItems.filter { $0.isSelected && $0.transferState != .done }
        guard !selected.isEmpty else {
            lastError = "Nessun file selezionato."
            return
        }

        for item in selected { item.transferState = .queued }
        downloadQueue = selected
        sessionItems = selected
        totalToCopy = selected.count
        copiedSoFar = 0
        itemsCompletedThisSession = []
        isCopying = true
        isPaused = false
        lastError = nil
        transferSummary = nil
        logger = TransferLogger(destinationFolder: root)

        _ = root.startAccessingSecurityScopedResource()
        fillDownloadSlots()
    }

    func pauseCopy() {
        isPaused = true
        statusMessage = "In pausa — \(copiedSoFar)/\(totalToCopy) completati."
    }

    func resumeCopy() {
        isPaused = false
        fillDownloadSlots()
    }

    func cancelCopy() {
        // Gli elementi non ancora avviati vengono marcati come annullati.
        // Quelli già in corso non possono essere interrotti a metà con
        // certezza (ImageCaptureCore non lo garantisce): li lasciamo
        // finire e ne registriamo comunque l'esito reale nel log.
        for item in downloadQueue {
            item.transferState = .failed("Annullato dall'utente")
            logger?.log(originalName: item.name, savedName: "-", status: "ANNULLATO", sizeBytes: nil, sha256: nil, detail: "Annullato prima dell'avvio")
        }
        copiedSoFar += downloadQueue.count
        downloadQueue = []
        cameraDevice?.cancelDownload()
        statusMessage = "Annullamento: attendo il completamento dei trasferimenti già avviati…"
        fillDownloadSlots()
    }

    func retryFailed() {
        let failedItems = mediaItems.filter { if case .failed = $0.transferState { return true }; return false }
        guard !failedItems.isEmpty, let root = destinationFolder else { return }

        for item in failedItems { item.transferState = .queued }
        downloadQueue.append(contentsOf: failedItems)
        sessionItems.append(contentsOf: failedItems)
        totalToCopy += failedItems.count
        isCopying = true
        isPaused = false
        transferSummary = nil

        if logger == nil { logger = TransferLogger(destinationFolder: root) }
        _ = root.startAccessingSecurityScopedResource()
        fillDownloadSlots()
    }

    // MARK: - Coda di download (con concorrenza limitata)

    private func fillDownloadSlots() {
        guard let camera = cameraDevice, let root = destinationFolder else {
            if activeDownloads.isEmpty { finishCopySession() }
            return
        }

        while !isPaused, activeDownloads.count < maxConcurrentDownloads, !downloadQueue.isEmpty {
            let item = downloadQueue.removeFirst()
            startDownload(item: item, camera: camera, root: root)
        }

        if activeDownloads.isEmpty && downloadQueue.isEmpty {
            finishCopySession()
        }
    }

    private func startDownload(item: MediaItem, camera: ICCameraDevice, root: URL) {
        let destFolder = organizeByDate
            ? FileOrganizer.destinationFolder(root: root, captureDate: item.captureDate, style: dateFolderStyle)
            : root

        do {
            try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        } catch {
            item.transferState = .failed("Impossibile creare la cartella: \(error.localizedDescription)")
            logger?.log(originalName: item.name, savedName: "-", status: "ERRORE", sizeBytes: nil, sha256: nil, detail: error.localizedDescription)
            copiedSoFar += 1
            return
        }

        let existingURL = destFolder.appendingPathComponent(item.name)
        let alreadyExists = FileManager.default.fileExists(atPath: existingURL.path)

        if alreadyExists && duplicatePolicy == .skip {
            item.transferState = .skipped
            logger?.log(originalName: item.name, savedName: item.name, status: "SALTATO", sizeBytes: item.fileSizeBytes, sha256: nil, detail: "Esiste già nella cartella")
            copiedSoFar += 1
            return
        }

        let finalName: String
        let overwrite: Bool
        switch duplicatePolicy {
        case .skip, .rename:
            finalName = alreadyExists ? FileOrganizer.uniqueFileName(for: item.name, in: destFolder) : item.name
            overwrite = false
        case .overwrite:
            finalName = item.name
            overwrite = true
        }

        let options: [ICDownloadOption: Any] = [
            ICDownloadOption.downloadsDirectoryURL: destFolder,
            ICDownloadOption.saveAsFilename: finalName,
            ICDownloadOption.overwrite: overwrite,
            ICDownloadOption.sidecarFiles: true
        ]

        activeDownloads[ObjectIdentifier(item.cameraItem)] = item
        item.transferState = .copying(progress: 0)
        statusMessage = "Copio \(item.name)… (\(copiedSoFar)/\(totalToCopy))"

        camera.requestDownloadFile(
            item.cameraItem,
            options: options,
            downloadDelegate: self,
            didDownloadSelector: #selector(DeviceManager.didDownloadFile(_:error:options:contextInfo:)),
            contextInfo: nil
        )
    }

    private func finishCopySession() {
        isCopying = false
        isPaused = false
        downloadQueue = []
        activeDownloads = [:]
        statusMessage = "Copia completata: \(copiedSoFar) di \(totalToCopy) file."
        destinationFolder?.stopAccessingSecurityScopedResource()
        logger?.close()
        logger = nil

        let copied = sessionItems.filter { if case .done = $0.transferState { return true }; return false }.count
        let skipped = sessionItems.filter { if case .skipped = $0.transferState { return true }; return false }.count
        let failed = sessionItems.filter { if case .failed = $0.transferState { return true }; return false }.count
        transferSummary = TransferSummary(copied: copied, skipped: skipped, failed: failed)
        sessionItems = []

        if deleteFromDeviceAfterCopy, !itemsCompletedThisSession.isEmpty {
            deleteFromDevice(itemsCompletedThisSession)
        }
        itemsCompletedThisSession = []
    }

    // MARK: - Eliminazione dall'iPhone dopo la copia

    private func deleteFromDevice(_ items: [MediaItem]) {
        guard let camera = cameraDevice else { return }
        let cameraItems = items.map { $0.cameraItem as ICCameraItem }

        statusMessage = "Elimino \(cameraItems.count) file dall'iPhone…"

        _ = camera.requestDeleteFiles(cameraItems, deleteFailed: { _ in
            // Eventuali singoli fallimenti non bloccano gli altri.
        }, completion: { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    self.statusMessage = "Copia completata. Alcuni file non sono stati eliminati dall'iPhone."
                } else {
                    self.statusMessage = "Copia completata ed elementi eliminati dall'iPhone."
                }
            }
        })
    }

    // MARK: - Conversioni opzionali (solo dopo verifica riuscita)

    private func runConversionsIfNeeded(destFolder: URL, savedFileName: String) {
        let localURL = destFolder.appendingPathComponent(savedFileName)

        if convertHEICtoJPEG, ConversionService.isHEIC(localURL) {
            DispatchQueue.global(qos: .utility).async {
                _ = ConversionService.convertHEICToJPEG(at: localURL)
            }
        }

        if convertVideoToH264, ConversionService.isVideo(localURL) {
            DispatchQueue.global(qos: .utility).async {
                ConversionService.convertVideoToH264(at: localURL) { _ in }
            }
        }
    }

    // MARK: - Gestione item ricevuti dal dispositivo

    private func addMediaItems(_ items: [ICCameraItem]) {
        let files = items.compactMap { $0 as? ICCameraFile }
        guard !files.isEmpty else { return }
        DispatchQueue.main.async {
            for file in files {
                let key = ObjectIdentifier(file)
                if self.mediaItemsByObjectID[key] != nil { continue }
                let item = MediaItem(cameraItem: file)
                self.mediaItemsByObjectID[key] = item
                self.mediaItems.append(item)
            }
            self.mediaItems.sort { (($0.captureDate ?? .distantPast)) > (($1.captureDate ?? .distantPast)) }
        }
    }
}

// MARK: - ICDeviceBrowserDelegate

extension DeviceManager: ICDeviceBrowserDelegate {

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        DispatchQueue.main.async {
            self.cameraDevice = camera
            camera.delegate = self
            self.deviceName = camera.name ?? "iPhone"
            self.statusMessage = "Connessione a \(self.deviceName)…"
            camera.requestOpenSession()
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard device === cameraDevice else { return }
        DispatchQueue.main.async {
            self.cameraDevice = nil
            self.isDeviceConnected = false
            self.isCatalogReady = false
            self.mediaItems = []
            self.mediaItemsByObjectID = [:]
            self.statusMessage = "Dispositivo scollegato. In attesa di un iPhone…"
        }
    }
}

// MARK: - ICDeviceDelegate (protocollo base, comune a tutti i device)

extension DeviceManager: ICDeviceDelegate {

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.statusMessage = "Errore apertura sessione: \(error.localizedDescription)"
                return
            }
            self.isDeviceConnected = true
            self.statusMessage = "Connesso a \(self.deviceName). Lettura contenuti…"
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        DispatchQueue.main.async { self.isDeviceConnected = false }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        // Per le fotocamere aspettiamo il segnale più specifico
        // "deviceDidBecomeReady(withCompleteContentCatalog:)" qui sotto.
    }

    func didRemove(_ device: ICDevice) {
        DispatchQueue.main.async {
            self.isDeviceConnected = false
            self.mediaItems = []
        }
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async {
            self.statusMessage = "Errore dispositivo: \(error.localizedDescription)"
        }
    }
}

// MARK: - ICCameraDeviceDelegate

extension DeviceManager: ICCameraDeviceDelegate {

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        addMediaItems(items)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        DispatchQueue.main.async {
            let removedIDs = Set(items.map(ObjectIdentifier.init))
            self.mediaItems.removeAll { removedIDs.contains(ObjectIdentifier($0.cameraItem)) }
        }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        if let all = device.mediaFiles {
            addMediaItems(all)
        }
        DispatchQueue.main.async {
            self.isCatalogReady = true
            self.statusMessage = "\(self.mediaItems.count) elementi trovati su \(self.deviceName)."
        }
    }

    // Dal 10.15 questi due metodi NON sono più opzionali nel protocollo:
    // vanno implementati anche solo con un corpo minimo. Non li usiamo per
    // il caricamento delle thumbnail (vedi loadThumbnailIfNeeded, che usa
    // requestThumbnailData ed è più affidabile), ma vanno comunque presenti.
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        DispatchQueue.main.async {
            guard let match = self.mediaItemsByObjectID[ObjectIdentifier(item)], let thumbnail, match.thumbnail == nil else { return }
            match.thumbnail = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {
        // Non usiamo i metadata: implementazione vuota richiesta solo per
        // soddisfare il protocollo (il metodo non è opzionale dal 10.15).
    }

    // I cinque metodi seguenti non hanno "optional" nell'interfaccia reale
    // di ICCameraDeviceDelegate: vanno implementati anche se qui non ci
    // servono, altrimenti la conformance al protocollo fallisce.

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        // Non gestiamo i rinomini in questa versione dell'app.
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        // Non ci serve reagire ai cambi di capability del dispositivo.
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        // Non inviamo comandi PTP, quindi non ci serve gestire questo evento.
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        DispatchQueue.main.async {
            self.statusMessage = "\(self.deviceName) sbloccato: lettura dei contenuti in corso…"
        }
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        DispatchQueue.main.async {
            self.statusMessage = "\(self.deviceName) è bloccato. Sblocca lo schermo dell'iPhone per continuare."
        }
    }
}

// MARK: - ICCameraDeviceDownloadDelegate

extension DeviceManager: ICCameraDeviceDownloadDelegate {

    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any] = [:], contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            let key = ObjectIdentifier(file)
            guard let item = self.activeDownloads[key] else {
                self.fillDownloadSlots()
                return
            }

            if let error {
                item.transferState = .failed(error.localizedDescription)
                self.logger?.log(originalName: item.name, savedName: "-", status: "ERRORE", sizeBytes: nil, sha256: nil, detail: error.localizedDescription)
                self.activeDownloads.removeValue(forKey: key)
                self.copiedSoFar += 1
                self.fillDownloadSlots()
                return
            }

            guard let destFolder = options[ICDownloadOption.downloadsDirectoryURL.rawValue] as? URL,
                  let savedName = options[ICDownloadOption.saveAsFilename.rawValue] as? String else {
                item.transferState = .done
                self.itemsCompletedThisSession.append(item)
                self.activeDownloads.removeValue(forKey: key)
                self.copiedSoFar += 1
                self.fillDownloadSlots()
                return
            }

            // Non liberiamo lo slot finché la verifica non è completata:
            // questo limita anche la concorrenza delle verifiche, ed evita
            // che il riepilogo finale scatti prima che tutte siano finite.
            item.transferState = .verifying
            let localURL = destFolder.appendingPathComponent(savedName)
            let expectedSize = item.fileSizeBytes

            DispatchQueue.global(qos: .utility).async {
                let result = TransferVerifier.verify(localURL: localURL, expectedSizeBytes: expectedSize)
                DispatchQueue.main.async {
                    switch result {
                    case .success(let sha256):
                        item.transferState = .done
                        self.logger?.log(originalName: item.name, savedName: savedName, status: "OK", sizeBytes: expectedSize, sha256: sha256, detail: nil)
                        self.itemsCompletedThisSession.append(item)
                        self.runConversionsIfNeeded(destFolder: destFolder, savedFileName: savedName)
                    case .failure(let reason):
                        item.transferState = .failed(reason)
                        self.logger?.log(originalName: item.name, savedName: savedName, status: "ERRORE_VERIFICA", sizeBytes: expectedSize, sha256: nil, detail: reason)
                    }
                    self.activeDownloads.removeValue(forKey: key)
                    self.copiedSoFar += 1
                    self.fillDownloadSlots()
                }
            }
        }
    }

    @objc func didReceiveDownloadProgress(for file: ICCameraFile, downloadedBytes: off_t, maxBytes: off_t) {
        DispatchQueue.main.async {
            guard let item = self.activeDownloads[ObjectIdentifier(file)], maxBytes > 0 else { return }
            item.transferState = .copying(progress: Double(downloadedBytes) / Double(maxBytes))
        }
    }
}
