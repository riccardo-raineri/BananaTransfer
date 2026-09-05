//
//  DeviceManager.swift
//  BananaTransfer
//
//  Cuore dell'app. Gestisce DUE tipi di sorgenti multimediali, scelte da
//  un menu a tendina nella UI:
//  1. fotocamera/iPhone via ImageCaptureCore (comportamento invariato
//     rispetto alle versioni precedenti: un dispositivo alla volta);
//  2. volumi USB/SD montati come disco normale, letti con FileManager
//     (nessuna relazione con ImageCaptureCore — un secondo "motore" più
//     semplice, dato che leggere un disco montato è un'operazione
//     sincrona e affidabile, senza sessioni/permessi da negoziare).
//  Entrambe le origini producono lo stesso modello MediaItem, quindi tutta
//  la logica di selezione, filtro, duplicati, verifica, log, conversione
//  è condivisa: solo il "download" vero e proprio (startCameraDownload vs
//  startLocalFileCopy) è specifico per origine.
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

struct LibraryScanSummary {
    let folderName: String
    let alreadyPresentCount: Int
    let totalScanned: Int

    var message: String {
        if totalScanned == 0 {
            return "Nessun elemento da confrontare (la griglia è vuota)."
        }
        if alreadyPresentCount == 0 {
            return "Nessuna corrispondenza trovata in \"\(folderName)\": tutti i \(totalScanned) elementi risultano nuovi."
        }
        return "\(alreadyPresentCount) di \(totalScanned) elementi risultano già presenti in \"\(folderName)\" e sono stati deselezionati."
    }
}

@objc final class DeviceManager: NSObject, ObservableObject {

    // MARK: - Stato pubblicato verso la UI

    @Published var isDeviceConnected = false
    @Published var deviceName: String = ""
    @Published var isCatalogReady = false
    @Published var isScanning = false
    @Published var isScanningLibrary = false
    @Published var statusMessage: String = "In attesa di un iPhone collegato via cavo…"
    @Published var logLines: [String] = []

    /// Elenco delle sorgenti selezionabili nel menu: la fotocamera
    /// attualmente connessa (se c'è) più tutti i volumi USB/SD rimovibili
    /// montati in questo momento.
    @Published var availableSources: [MediaSourceOption] = []
    @Published var selectedSourceID: String?

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
    @Published var libraryScanSummary: LibraryScanSummary?

    /// Elementi letti dalla fotocamera/iPhone attualmente connessa.
    @Published private var cameraMediaItems: [MediaItem] = []
    /// Elementi trovati nell'ultima scansione di un volume USB/SD.
    @Published private var volumeMediaItems: [MediaItem] = []

    static let cameraSourceID = "camera"

    /// Elenco effettivo mostrato in griglia: dipende da quale sorgente è
    /// selezionata nel menu. Se non è selezionato un volume, mostriamo
    /// sempre il catalogo della fotocamera (comportamento identico alle
    /// versioni precedenti quando non c'erano altre sorgenti).
    var mediaItems: [MediaItem] {
        if let id = selectedSourceID,
           availableSources.first(where: { $0.id == id })?.kind == .volume {
            return volumeMediaItems
        }
        return cameraMediaItems
    }

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
    private var cameraItemsByObjectID: [ObjectIdentifier: MediaItem] = [:]
    private var requestedThumbnails: Set<AnyHashable> = []
    /// Propaga i cambiamenti di ogni singolo MediaItem (es. isSelected
    /// quando l'utente tocca una cella) fino al DeviceManager stesso: senza
    /// questo, le viste che osservano solo il DeviceManager (come
    /// ContentView, per il conteggio "Trasferisci N elementi") non si
    /// accorgono che qualcosa è cambiato in un MediaItem figlio, perché
    /// SwiftUI non fa risalire automaticamente gli @Published annidati.
    private var itemSubscriptions: [AnyHashable: AnyCancellable] = [:]

    /// Quanti download tenere attivi in parallelo. La verifica di
    /// integrità (dimensione + SHA-256) occupa lo slot fino al termine,
    /// quindi questo numero limita anche quante verifiche girano insieme.
    private let maxConcurrentDownloads = 3

    private var downloadQueue: [MediaItem] = []
    private var activeDownloads: [AnyHashable: MediaItem] = [:]
    private var itemsCompletedThisSession: [MediaItem] = []
    private var sessionItems: [MediaItem] = []
    private var logger: TransferLogger?
    private var refreshTimer: Timer?
    private var refreshAttempts = 0
    private var lastKnownCount = -1

    private var currentVolumeOptions: [MediaSourceOption] = []

    // MARK: - Ciclo di vita

    override init() {
        super.init()
        destinationFolder = FolderPickerService.restoreLastFolder()

        deviceBrowser.delegate = self
        deviceBrowser.browsedDeviceTypeMask = .camera
        deviceBrowser.start()
        log("App avviata, scansione dispositivi in corso…")
        isScanning = true

        startVolumeWatching()

        // Se l'iPhone era già collegato prima di aprire l'app,
        // ICDeviceBrowser a volte non lo segnala retroattivamente. Proviamo
        // UNA SOLA volta a riavviare la scansione dopo qualche secondo.
        // Importante: farlo ripetutamente confonde lo stato interno di
        // ICDeviceBrowser e può causare falsi eventi di collegamento/
        // scollegamento a catena — da cui derivava un loop di scansione
        // infinito osservato in una versione precedente.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.cameraDevice == nil else { return }
            self.log("Nessun dispositivo dopo l'avvio, riprovo una volta la scansione…")
            self.deviceBrowser.stop()
            self.deviceBrowser.start()

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self, self.cameraDevice == nil else { return }
                self.isScanning = false
                if self.availableSources.isEmpty {
                    self.statusMessage = "Nessun iPhone o volume rilevato. Controlla il cavo o ricollega il dispositivo."
                }
                self.log("Nessuna fotocamera rilevata dopo il secondo tentativo.")
            }
        }
    }

    /// Rilegge ripetutamente il catalogo di UN dispositivo già rilevato,
    /// finché il conteggio non si stabilizza (due letture di fila uguali,
    /// non-zero) — copre il caso in cui il catalogo risulti vuoto o
    /// incompleto perché letto troppo presto (es. telefono ancora bloccato).
    /// Non tocca mai ICDeviceBrowser: se il dispositivo sparisce, si ferma
    /// e basta, senza tentare di "aggiustare" nulla a livello di scansione USB.
    private func startCatalogPolling() {
        refreshTimer?.invalidate()
        refreshAttempts = 0
        lastKnownCount = -1
        isScanning = true
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }

            guard let camera = self.cameraDevice else {
                timer.invalidate()
                self.refreshTimer = nil
                self.isScanning = false
                return
            }

            self.refreshAttempts += 1
            let all = camera.mediaFiles ?? []
            self.addCameraMediaItems(all) {
                let currentCount = self.cameraMediaItems.count
                if currentCount > 0 {
                    self.isCatalogReady = true
                    self.statusMessage = "\(currentCount) elementi trovati su \(self.deviceName)."
                }

                if currentCount > 0 && currentCount == self.lastKnownCount {
                    self.log("Catalogo stabile a \(currentCount) elementi, fermo il refresh automatico.")
                    timer.invalidate()
                    self.refreshTimer = nil
                    self.isScanning = false
                } else {
                    if currentCount != self.lastKnownCount {
                        self.log("Catalogo: \(currentCount) elementi (tentativo \(self.refreshAttempts))")
                    }
                    self.lastKnownCount = currentCount
                }
            }

            if self.refreshAttempts >= 60 {
                self.log("Refresh automatico terminato dopo \(self.refreshAttempts) tentativi.")
                timer.invalidate()
                self.refreshTimer = nil
                self.isScanning = false
            }
        }
    }

    deinit {
        deviceBrowser.stop()
        refreshTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Registro operazioni in tempo reale

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func log(_ message: String) {
        let line = "[\(Self.logTimeFormatter.string(from: Date()))] \(message)"
        if Thread.isMainThread {
            logLines.append(line)
            if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        } else {
            DispatchQueue.main.async {
                self.logLines.append(line)
                if self.logLines.count > 500 { self.logLines.removeFirst(self.logLines.count - 500) }
            }
        }
    }

    // MARK: - Sorgenti multiple (fotocamera + volumi USB/SD)

    /// Osserva i volumi che vengono montati/smontati (chiavette USB,
    /// schede SD lette con un lettore, dischi esterni) per tenere
    /// aggiornato il menu delle sorgenti disponibili.
    private func startVolumeWatching() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleVolumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleVolumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleVolumesChanged), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        refreshVolumeList()
    }

    @objc private func handleVolumesChanged() {
        refreshVolumeList()
    }

    /// Rilegge l'elenco dei volumi montati e tiene solo quelli rimovibili
    /// (USB/SD/dischi esterni) — esclude il disco di avvio interno e altri
    /// volumi di sistema, che non hanno senso come "sorgente da cui
    /// importare foto".
    private func refreshVolumeList() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        var options: [MediaSourceOption] = []
        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isRemovable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            let isInternal = values.volumeIsInternal ?? true
            guard isRemovable, !isInternal else { continue }
            let name = values.volumeName ?? url.lastPathComponent
            options.append(MediaSourceOption(id: url.path, name: name, systemImage: "sdcard", kind: .volume))
        }

        let removedIDs = Set(currentVolumeOptions.map(\.id)).subtracting(options.map(\.id))
        if removedIDs.contains(selectedSourceID ?? "") {
            // Il volume attualmente selezionato è stato espulso: puliamo
            // la vista, il menu si riaggiornerà da solo qui sotto.
            volumeMediaItems = []
            selectedSourceID = nil
            statusMessage = "Volume rimosso. Seleziona un'altra sorgente."
        }

        currentVolumeOptions = options
        if !options.isEmpty {
            log("Volumi rimovibili rilevati: \(options.map(\.name).joined(separator: ", "))")
        }
        rebuildAvailableSources()
    }

    private func rebuildAvailableSources() {
        var sources: [MediaSourceOption] = []
        if cameraDevice != nil {
            sources.append(MediaSourceOption(
                id: Self.cameraSourceID,
                name: deviceName.isEmpty ? "Fotocamera" : deviceName,
                systemImage: "iphone",
                kind: .camera
            ))
        }
        sources.append(contentsOf: currentVolumeOptions)
        self.availableSources = sources

        if selectedSourceID == nil || !sources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = sources.first?.id
        }
    }

    /// Chiamato dalla UI quando l'utente sceglie una voce dal menu sorgenti.
    func selectSource(_ id: String) {
        guard id != selectedSourceID else { return }
        selectedSourceID = id
        guard let option = availableSources.first(where: { $0.id == id }) else { return }

        if option.kind == .volume {
            log("Sorgente selezionata: volume \(option.name)")
            scanVolume(path: option.id, name: option.name)
        } else {
            log("Sorgente selezionata: fotocamera \(option.name)")
            statusMessage = cameraMediaItems.isEmpty
                ? "Lettura contenuti…"
                : "\(cameraMediaItems.count) elementi trovati su \(deviceName)."
        }
    }

    private func scanVolume(path: String, name: String) {
        isScanning = true
        statusMessage = "Scansione di \(name) in corso…"
        volumeMediaItems = []

        let root = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .userInitiated).async {
            let items = VolumeScanner.scanMedia(root: root)
            let sorted = items.sorted { (($0.captureDate ?? .distantPast)) > (($1.captureDate ?? .distantPast)) }

            DispatchQueue.main.async {
                // Se nel frattempo l'utente ha selezionato un'altra
                // sorgente, scartiamo questo risultato: non ha più senso.
                guard self.selectedSourceID == path else { return }

                for item in sorted {
                    self.itemSubscriptions[item.sourceKey] = item.objectWillChange.sink { [weak self] _ in
                        self?.objectWillChange.send()
                    }
                }
                self.volumeMediaItems = sorted
                self.isScanning = false
                self.isCatalogReady = true
                self.statusMessage = "\(sorted.count) elementi trovati su \(name)."
                self.log("Scansione di \(name) completata: \(sorted.count) elementi.")
            }
        }
    }

    // MARK: - Azioni richiamate dalla UI

    func chooseDestinationFolder(window: NSWindow?) {
        if let url = FolderPickerService.chooseFolder(currentWindow: window) {
            destinationFolder = url
        }
    }

    /// Apre un selettore cartella, la scansiona in background per trovare
    /// file già presenti (per nome+dimensione), e marca gli elementi
    /// corrispondenti come "già in libreria", deselezionandoli
    /// automaticamente per non ricopiarli per errore.
    func scanExistingLibrary(window: NSWindow?) {
        guard let root = FolderPickerService.chooseFolder(currentWindow: window) else { return }

        isScanningLibrary = true
        statusMessage = "Verifico i file già presenti in \(root.lastPathComponent)…"
        log("Avvio verifica libreria esistente: \(root.path)")

        DispatchQueue.global(qos: .userInitiated).async {
            let fingerprints = LibraryScanner.scanFingerprints(root: root)

            DispatchQueue.main.async {
                var matchCount = 0
                for item in self.mediaItems {
                    let fp = LibraryScanner.fingerprint(name: item.name, sizeBytes: item.fileSizeBytes)
                    let alreadyThere = fingerprints.contains(fp)
                    item.isAlreadyInLibrary = alreadyThere
                    if alreadyThere {
                        item.isSelected = false
                        matchCount += 1
                    }
                }
                self.isScanningLibrary = false
                let summary = LibraryScanSummary(
                    folderName: root.lastPathComponent,
                    alreadyPresentCount: matchCount,
                    totalScanned: self.mediaItems.count
                )
                self.libraryScanSummary = summary
                self.statusMessage = summary.message
                self.log("Verifica completata: \(matchCount) elementi già presenti su \(self.mediaItems.count) totali.")
            }
        }
    }

    func toggleSelectAll(_ selected: Bool) {
        // Agisce solo sugli elementi attualmente visibili col filtro
        // Foto/Video attivo: più intuitivo che selezionare anche quelli nascosti.
        for item in filteredMediaItems { item.isSelected = selected }
    }

    func loadThumbnailIfNeeded(for item: MediaItem) {
        guard item.thumbnail == nil else { return }
        let key = item.sourceKey
        guard !requestedThumbnails.contains(key) else { return }
        requestedThumbnails.insert(key)

        switch item.origin {
        case .camera(let file):
            file.requestThumbnailData(options: nil) { data, error in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { item.thumbnail = image }
            }
        case .localFile(let url):
            DispatchQueue.global(qos: .utility).async {
                guard let image = NSImage(contentsOf: url) else { return }
                let thumb = image.bt_resizedThumbnail(maxDimension: 220)
                DispatchQueue.main.async { item.thumbnail = thumb }
            }
        }
    }

    func startCopySelected() {
        guard let root = destinationFolder else {
            lastError = "Scegli prima una cartella di destinazione sull'HDD."
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
        log("Avvio copia di \(selected.count) elementi verso \(root.lastPathComponent)")
        fillDownloadSlots()
    }

    func pauseCopy() {
        isPaused = true
        statusMessage = "In pausa — \(copiedSoFar)/\(totalToCopy) completati."
        log("Copia in pausa (\(copiedSoFar)/\(totalToCopy))")
    }

    func resumeCopy() {
        isPaused = false
        log("Copia ripresa")
        fillDownloadSlots()
    }

    func cancelCopy() {
        // Gli elementi non ancora avviati vengono marcati come annullati.
        // Quelli già in corso non possono essere interrotti a metà con
        // certezza (per la fotocamera ImageCaptureCore non lo garantisce):
        // li lasciamo finire e ne registriamo comunque l'esito reale nel log.
        log("Annullamento richiesto: \(downloadQueue.count) elementi in coda scartati")
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
        guard let root = destinationFolder else {
            if activeDownloads.isEmpty { finishCopySession() }
            return
        }

        while !isPaused, activeDownloads.count < maxConcurrentDownloads, !downloadQueue.isEmpty {
            let item = downloadQueue.removeFirst()
            startDownload(item: item, root: root)
        }

        if activeDownloads.isEmpty && downloadQueue.isEmpty {
            finishCopySession()
        }
    }

    private func startDownload(item: MediaItem, root: URL) {
        switch item.origin {
        case .camera(let file):
            guard let camera = cameraDevice else {
                item.transferState = .failed("Fotocamera non più connessa")
                logger?.log(originalName: item.name, savedName: "-", status: "ERRORE", sizeBytes: nil, sha256: nil, detail: "Fotocamera non più connessa")
                copiedSoFar += 1
                return
            }
            startCameraDownload(item: item, file: file, camera: camera, root: root)
        case .localFile(let sourceURL):
            startLocalFileCopy(item: item, sourceURL: sourceURL, root: root)
        }
    }

    private func startCameraDownload(item: MediaItem, file: ICCameraFile, camera: ICCameraDevice, root: URL) {
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

        activeDownloads[item.sourceKey] = item
        item.transferState = .copying(progress: 0)
        statusMessage = "Copio \(item.name)… (\(copiedSoFar)/\(totalToCopy))"

        camera.requestDownloadFile(
            file,
            options: options,
            downloadDelegate: self,
            didDownloadSelector: #selector(DeviceManager.didDownloadFile(_:error:options:contextInfo:)),
            contextInfo: nil
        )
    }

    /// Copia un file da un volume USB/SD già montato: qui non c'è nessuna
    /// sessione/protocollo da negoziare come con la fotocamera, è una
    /// semplice copia di file, ma passa comunque dalla stessa verifica di
    /// integrità (dimensione + SHA-256) e dallo stesso registro delle altre
    /// origini, per la stessa garanzia di affidabilità.
    private func startLocalFileCopy(item: MediaItem, sourceURL: URL, root: URL) {
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

        let finalName: String = (alreadyExists && duplicatePolicy == .rename)
            ? FileOrganizer.uniqueFileName(for: item.name, in: destFolder)
            : item.name
        let localPath = destFolder.appendingPathComponent(finalName)
        let expectedSize = item.fileSizeBytes
        let policy = duplicatePolicy

        activeDownloads[item.sourceKey] = item
        item.transferState = .copying(progress: 0)
        statusMessage = "Copio \(item.name)… (\(copiedSoFar)/\(totalToCopy))"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if policy == .overwrite, FileManager.default.fileExists(atPath: localPath.path) {
                    try FileManager.default.removeItem(at: localPath)
                }
                try FileManager.default.copyItem(at: sourceURL, to: localPath)

                DispatchQueue.main.async { item.transferState = .verifying }

                let result = TransferVerifier.verify(localURL: localPath, expectedSizeBytes: expectedSize)
                DispatchQueue.main.async {
                    self.finishItemCopy(item: item, result: result, destFolder: destFolder, savedName: finalName)
                }
            } catch {
                DispatchQueue.main.async {
                    item.transferState = .failed(error.localizedDescription)
                    self.logger?.log(originalName: item.name, savedName: "-", status: "ERRORE", sizeBytes: nil, sha256: nil, detail: error.localizedDescription)
                    self.log("✗ \(item.name): \(error.localizedDescription)")
                    self.activeDownloads.removeValue(forKey: item.sourceKey)
                    self.copiedSoFar += 1
                    self.fillDownloadSlots()
                }
            }
        }
    }

    /// Logica condivisa dopo la verifica di integrità, usata sia dal
    /// percorso fotocamera sia da quello volume: aggiorna stato, registro,
    /// avvia eventuali conversioni, e fa avanzare la coda.
    private func finishItemCopy(item: MediaItem, result: TransferVerifier.VerificationResult, destFolder: URL, savedName: String) {
        switch result {
        case .success(let sha256):
            item.transferState = .done
            logger?.log(originalName: item.name, savedName: savedName, status: "OK", sizeBytes: item.fileSizeBytes, sha256: sha256, detail: nil)
            log("✓ \(item.name) copiato e verificato")
            itemsCompletedThisSession.append(item)
            runConversionsIfNeeded(destFolder: destFolder, savedFileName: savedName)
        case .failure(let reason):
            item.transferState = .failed(reason)
            logger?.log(originalName: item.name, savedName: savedName, status: "ERRORE_VERIFICA", sizeBytes: item.fileSizeBytes, sha256: nil, detail: reason)
            log("✗ \(item.name): verifica fallita — \(reason)")
        }
        activeDownloads.removeValue(forKey: item.sourceKey)
        copiedSoFar += 1
        fillDownloadSlots()
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
        log("Copia completata: \(copied) copiati, \(skipped) saltati, \(failed) falliti")
        sessionItems = []

        if deleteFromDeviceAfterCopy, !itemsCompletedThisSession.isEmpty {
            deleteFromSourceAfterCopy(itemsCompletedThisSession)
        }
        itemsCompletedThisSession = []
    }

    // MARK: - Eliminazione dalla sorgente dopo la copia

    /// Elimina i file originali dopo che la copia è stata verificata: per
    /// la fotocamera usa l'API dedicata di ImageCaptureCore, per un volume
    /// USB/SD è semplicemente la cancellazione del file locale.
    private func deleteFromSourceAfterCopy(_ items: [MediaItem]) {
        let cameraItems: [ICCameraItem] = items.compactMap {
            if case .camera(let file) = $0.origin { return file }
            return nil
        }
        let localURLs: [URL] = items.compactMap {
            if case .localFile(let url) = $0.origin { return url }
            return nil
        }

        if !cameraItems.isEmpty, let camera = cameraDevice {
            statusMessage = "Elimino \(cameraItems.count) file dall'iPhone…"
            _ = camera.requestDeleteFiles(cameraItems, deleteFailed: { _ in
                // Eventuali singoli fallimenti non bloccano gli altri.
            }, completion: { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statusMessage = error != nil
                        ? "Copia completata. Alcuni file non sono stati eliminati dall'iPhone."
                        : "Copia completata ed elementi eliminati dall'iPhone."
                }
            })
        }

        if !localURLs.isEmpty {
            var deletedCount = 0
            for url in localURLs {
                if (try? FileManager.default.removeItem(at: url)) != nil { deletedCount += 1 }
            }
            log("Eliminati \(deletedCount) file dal volume sorgente dopo la copia")
        }
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

    // MARK: - Gestione item ricevuti dalla fotocamera

    private func addCameraMediaItems(_ items: [ICCameraItem], completion: (() -> Void)? = nil) {
        let files = items.compactMap { $0 as? ICCameraFile }
        guard !files.isEmpty else {
            DispatchQueue.main.async { completion?() }
            return
        }
        DispatchQueue.main.async {
            for file in files {
                let key = ObjectIdentifier(file)
                if self.cameraItemsByObjectID[key] != nil { continue }
                let item = MediaItem(cameraItem: file)
                self.cameraItemsByObjectID[key] = item
                self.cameraMediaItems.append(item)
                self.itemSubscriptions[item.sourceKey] = item.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
            }
            self.cameraMediaItems.sort { (($0.captureDate ?? .distantPast)) > (($1.captureDate ?? .distantPast)) }
            completion?()
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
            self.log("Dispositivo rilevato: \(self.deviceName)")
            self.rebuildAvailableSources()
            self.startCatalogPolling()
            camera.requestOpenSession()
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard device === cameraDevice else { return }
        DispatchQueue.main.async {
            self.log("Dispositivo scollegato: \(self.deviceName)")
            self.cameraDevice = nil
            self.isDeviceConnected = false
            self.isCatalogReady = false
            self.cameraMediaItems = []
            self.cameraItemsByObjectID = [:]
            self.statusMessage = "Dispositivo scollegato. In attesa di un iPhone…"
            self.refreshTimer?.invalidate()
            self.refreshTimer = nil
            self.isScanning = false
            self.rebuildAvailableSources()
        }
    }
}

// MARK: - ICDeviceDelegate (protocollo base, comune a tutti i device)

extension DeviceManager: ICDeviceDelegate {

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.statusMessage = "Errore apertura sessione: \(error.localizedDescription)"
                self.log("Errore apertura sessione: \(error.localizedDescription)")
                return
            }
            self.isDeviceConnected = true
            self.statusMessage = "Connesso a \(self.deviceName). Lettura contenuti…"
            self.log("Sessione aperta con \(self.deviceName)")

            if let camera = self.cameraDevice {
                let all = camera.mediaFiles ?? []
                self.addCameraMediaItems(all) {
                    if !self.cameraMediaItems.isEmpty {
                        self.isCatalogReady = true
                        self.statusMessage = "\(self.cameraMediaItems.count) elementi trovati su \(self.deviceName)."
                    }
                }
            }
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
            self.cameraMediaItems = []
            self.cameraItemsByObjectID = [:]
            self.refreshTimer?.invalidate()
            self.refreshTimer = nil
            self.isScanning = false
            self.rebuildAvailableSources()
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
        addCameraMediaItems(items)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        DispatchQueue.main.async {
            let removedIDs = Set(items.map(ObjectIdentifier.init))
            self.cameraMediaItems.removeAll { item in
                if case .camera(let file) = item.origin { return removedIDs.contains(ObjectIdentifier(file)) }
                return false
            }
            for id in removedIDs {
                self.cameraItemsByObjectID.removeValue(forKey: id)
                self.itemSubscriptions.removeValue(forKey: AnyHashable(id))
            }
        }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let all = device.mediaFiles ?? []
        addCameraMediaItems(all) {
            self.isCatalogReady = true
            if self.cameraMediaItems.isEmpty {
                // A volte "mediaFiles" non è ancora popolato internamente
                // nell'istante esatto in cui questo delegate scatta, pur
                // essendo il segnale ufficiale di "catalogo pronto". Un
                // secondo ripescaggio dopo una breve attesa recupera gli
                // elementi in questi casi, invece di restare bloccati su
                // "0 elementi trovati".
                self.statusMessage = "Catalogo pronto, verifico il contenuto…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let retryItems = device.mediaFiles ?? []
                    self.addCameraMediaItems(retryItems) {
                        self.statusMessage = "\(self.cameraMediaItems.count) elementi trovati su \(self.deviceName)."
                    }
                }
            } else {
                self.statusMessage = "\(self.cameraMediaItems.count) elementi trovati su \(self.deviceName)."
            }
        }
    }

    // Dal 10.15 questi due metodi NON sono più opzionali nel protocollo:
    // vanno implementati anche solo con un corpo minimo. Non li usiamo per
    // il caricamento delle thumbnail (vedi loadThumbnailIfNeeded, che usa
    // requestThumbnailData ed è più affidabile), ma vanno comunque presenti.
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        DispatchQueue.main.async {
            guard let match = self.cameraItemsByObjectID[ObjectIdentifier(item)], let thumbnail, match.thumbnail == nil else { return }
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
            self.startCatalogPolling()
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
            let key = AnyHashable(ObjectIdentifier(file))
            guard let item = self.activeDownloads[key] else {
                self.fillDownloadSlots()
                return
            }

            if let error {
                item.transferState = .failed(error.localizedDescription)
                self.logger?.log(originalName: item.name, savedName: "-", status: "ERRORE", sizeBytes: nil, sha256: nil, detail: error.localizedDescription)
                self.log("✗ \(item.name): \(error.localizedDescription)")
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
                    self.finishItemCopy(item: item, result: result, destFolder: destFolder, savedName: savedName)
                }
            }
        }
    }

    @objc func didReceiveDownloadProgress(for file: ICCameraFile, downloadedBytes: off_t, maxBytes: off_t) {
        DispatchQueue.main.async {
            guard let item = self.activeDownloads[AnyHashable(ObjectIdentifier(file))], maxBytes > 0 else { return }
            item.transferState = .copying(progress: Double(downloadedBytes) / Double(maxBytes))
        }
    }
}

// MARK: - Utility

private extension NSImage {
    /// Ridimensiona l'immagine per non tenere in RAM foto a piena
    /// risoluzione solo per mostrarne una miniatura di ~200px.
    func bt_resizedThumbnail(maxDimension: CGFloat) -> NSImage {
        let scale = maxDimension / max(size.width, size.height)
        guard scale < 1, scale > 0 else { return self }
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1)
        newImage.unlockFocus()
        return newImage
    }
}
