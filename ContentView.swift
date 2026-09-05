//
//  ContentView.swift
//  BananaTransfer
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject var manager: DeviceManager
    @State private var isLogVisible = false
    @AppStorage("preferLightTheme") private var preferLightTheme = false

    private var currentSource: MediaSourceOption? {
        manager.availableSources.first(where: { $0.id == manager.selectedSourceID })
    }

    var body: some View {
        VStack(spacing: 0) {
            
            // MARK: - Header
            headerBar
            
            Divider().opacity(0.5)

            // MARK: - Main Area
            ZStack {
                Color(NSColor.windowBackgroundColor).ignoresSafeArea()
                
                if manager.mediaItems.isEmpty {
                    elegantEmptyState
                } else {
                    PhotoGridView()
                        .padding(.top, 10)
                }
            }

            Divider().opacity(0.5)
            
            // MARK: - Bottom Control Panel
            bottomControlPanel

            // MARK: - Registro operazioni
            logPanel
        }
        .frame(minWidth: 700, idealWidth: 800, minHeight: 600, idealHeight: 700)
        .preferredColorScheme(preferLightTheme ? .light : .dark)
        // MARK: - Alerts (Invariati dal tuo codice)
        .alert("Errore", isPresented: Binding(
            get: { manager.lastError != nil },
            set: { if !$0 { manager.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { manager.lastError = nil }
        } message: {
            Text(manager.lastError ?? "")
        }
        .alert("Trasferimento completato", isPresented: Binding(
            get: { manager.transferSummary != nil },
            set: { if !$0 { manager.transferSummary = nil } }
        )) {
            Button("OK", role: .cancel) { manager.transferSummary = nil }
        } message: {
            Text(manager.transferSummary?.message ?? "")
        }
        .alert("Verifica libreria completata", isPresented: Binding(
            get: { manager.libraryScanSummary != nil },
            set: { if !$0 { manager.libraryScanSummary = nil } }
        )) {
            Button("OK", role: .cancel) { manager.libraryScanSummary = nil }
        } message: {
            Text(manager.libraryScanSummary?.message ?? "")
        }
    }

    // MARK: - Sotto-viste Ridisegnate

    private var headerBar: some View {
        HStack(spacing: 16) {
            // Titolo e Status
            VStack(alignment: .leading, spacing: 4) {
                Text(manager.deviceName.isEmpty ? "Nessun iPhone collegato" : manager.deviceName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(manager.deviceName.isEmpty ? .secondary : .primary)
                
                HStack(spacing: 6) {
                    if manager.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(manager.statusMessage.isEmpty ? "In attesa di connessione..." : manager.statusMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(manager.deviceName.isEmpty ? .tertiary : .secondary)
                }
            }

            Spacer()

            if !manager.availableSources.isEmpty {
                Menu {
                    ForEach(manager.availableSources) { source in
                        Button {
                            manager.selectSource(source.id)
                        } label: {
                            Label(source.name, systemImage: source.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: currentSource?.systemImage ?? "questionmark.circle")
                        Text(currentSource?.name ?? "Scegli sorgente")
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Scegli da quale dispositivo o volume importare i file")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { preferLightTheme.toggle() }
            } label: {
                Image(systemName: preferLightTheme ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(preferLightTheme ? "Passa al tema scuro" : "Passa al tema chiaro")

            // Filtri e Selezione (Visibili solo se ci sono elementi)
            if !manager.mediaItems.isEmpty {
                Picker("", selection: $manager.kindFilter) {
                    ForEach(MediaKindFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()

                Divider().frame(height: 20).padding(.horizontal, 4)

                HStack(spacing: 8) {
                    Button {
                        manager.toggleSelectAll(true)
                    } label: {
                        Label("Seleziona tutto", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())

                    Button {
                        manager.toggleSelectAll(false)
                    } label: {
                        Label("Deseleziona tutto", systemImage: "circle")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var elegantEmptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 140, height: 140)
                
                Image(systemName: manager.deviceName.isEmpty ? "iphone.slash" : "iphone.and.arrow.forward")
                    .font(.system(size: 56, weight: .light))
                    .foregroundColor(manager.deviceName.isEmpty ? .secondary : .accentColor)
            }
            
            VStack(spacing: 8) {
                Text(manager.deviceName.isEmpty ? "Collega il tuo iPhone" : manager.deviceName)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))

                HStack(spacing: 6) {
                    if manager.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(manager.deviceName.isEmpty ? "Usa un cavo USB per connettere il dispositivo" : "Il dispositivo è connesso. Sto scansionando gli elementi multimediali...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomControlPanel: some View {
        VStack(spacing: 20) {
            // Pannello Impostazioni (compatto e raggruppato)
            if !manager.mediaItems.isEmpty {
                VStack(spacing: 12) {
                    // Riga 1: Organizzazione e Destinazione
                    HStack {
                        Text("Scegli cartella di destinazione:")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        Button {
                            manager.chooseDestinationFolder(window: NSApp.keyWindow)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.accentColor)
                                Text(manager.destinationFolder?.lastPathComponent ?? "Scegli...")
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)

                        Button {
                            manager.scanExistingLibrary(window: NSApp.keyWindow)
                        } label: {
                            HStack {
                                if manager.isScanningLibrary {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "magnifyingglass")
                                }
                                Text("Verifica libreria esistente…")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(manager.isScanningLibrary)
                        .help("Scansiona una cartella sul Mac per trovare file già trasferiti in passato e deselezionarli automaticamente")

                        Spacer()

                        Toggle("Crea cartella per Data:", isOn: $manager.organizeByDate)
                        if manager.organizeByDate {
                            Picker("", selection: $manager.dateFolderStyle) {
                                ForEach(DateFolderStyle.allCases) { style in
                                    Text(style.label).tag(style)
                                }
                            }
                            .frame(width: 130)
                            .labelsHidden()
                        }
                        
                        Divider().frame(height: 16).padding(.horizontal, 4)
                        
                        Text("Duplicati:")
                        Picker("", selection: $manager.duplicatePolicy) {
                            ForEach(DuplicatePolicy.allCases) { policy in
                                Text(policy.rawValue).tag(policy)
                            }
                        }
                        .frame(width: 120)
                        .labelsHidden()
                    }

                    // Riga 2: Conversioni ed Eliminazione
                    HStack(spacing: 24) {
                        Toggle("Converti da HEIC in JPEG", isOn: $manager.convertHEICtoJPEG)
                        Toggle("Converti video in H.264 (1920x1080)", isOn: $manager.convertVideoToH264)
                        Spacer()
                        Toggle("Elimina dall'iPhone dopo la copia", isOn: $manager.deleteFromDeviceAfterCopy)
                            .tint(.red) // Dà un accento rosso per le azioni distruttive
                    }
                    .foregroundColor(.secondary)
                }
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Barra di Progresso e Pulsante Principale
            progressAndActionBar
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
    }

    @ViewBuilder
    private var progressAndActionBar: some View {
        HStack {
            // Sezione Sinistra: Progresso o Azioni di recupero
            if manager.isCopying {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(manager.copiedSoFar), total: Double(max(manager.totalToCopy, 1)))
                        .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                        .frame(maxWidth: 300)
                    
                    HStack(spacing: 12) {
                        Text("Trasferito: \(manager.copiedSoFar) di \(manager.totalToCopy)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        // Controlli di pausa/ripresa
                        if manager.isPaused {
                            Button(action: { manager.resumeCopy() }) {
                                Image(systemName: "play.circle.fill").foregroundColor(.accentColor)
                            }.buttonStyle(.plain)
                        } else {
                            Button(action: { manager.pauseCopy() }) {
                                Image(systemName: "pause.circle.fill").foregroundColor(.orange)
                            }.buttonStyle(.plain)
                        }
                        
                        Button(action: { manager.cancelCopy() }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                        }.buttonStyle(.plain)
                    }
                }
            } else if manager.hasFailedItems {
                Button {
                    manager.retryFailed()
                } label: {
                    Label("Riprova i file falliti", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
            } else {
                Spacer()
            }

            Spacer()

            // Pulsante Principale
            let selectedCount = manager.mediaItems.filter { $0.isSelected }.count
            
            Button {
                manager.startCopySelected()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: manager.isCopying ? "arrow.2.circlepath" : "square.and.arrow.down.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(manager.isCopying ? "In corso..." : "Trasferisci \(selectedCount) elementi")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                // Se non c'è una destinazione o non ci sono file, il bottone è grigio. Altrimenti è Giallo Banana.
                .background(selectedCount > 0 && manager.destinationFolder != nil && !manager.isCopying ? Color.accentColor : Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: selectedCount > 0 && manager.destinationFolder != nil && !manager.isCopying ? Color.accentColor.opacity(0.4) : Color.clear, radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCount == 0 || manager.destinationFolder == nil || manager.isCopying)
        }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isLogVisible.toggle() }
            } label: {
                HStack {
                    Image(systemName: "terminal")
                    Text(isLogVisible ? "Nascondi registro" : "Mostra registro")
                    if manager.isScanning {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    Image(systemName: isLogVisible ? "chevron.down" : "chevron.up")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isLogVisible {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(manager.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 6)
                    }
                    .frame(height: 160)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .onChange(of: manager.logLines.count) { _ in
                        if let lastIndex = manager.logLines.indices.last {
                            withAnimation { proxy.scrollTo(lastIndex, anchor: .bottom) }
                        }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

#Preview {
    ContentView()
        .environmentObject(DeviceManager())
}
