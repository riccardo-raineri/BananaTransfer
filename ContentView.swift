//
//  ContentView.swift
//  BananaTransfer
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject var manager: DeviceManager

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if manager.mediaItems.isEmpty {
                emptyState
            } else {
                PhotoGridView()
            }

            Divider()
            bottomBar
        }
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
    }

    // MARK: - Sotto-viste

    private var toolbar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.deviceName.isEmpty ? "Nessun iPhone collegato" : manager.deviceName)
                    .font(.headline)
                Text(manager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $manager.kindFilter) {
                ForEach(MediaKindFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .labelsHidden()

            Button {
                manager.toggleSelectAll(true)
            } label: {
                Label("Seleziona tutto", systemImage: "checkmark.circle")
            }
            .disabled(manager.mediaItems.isEmpty)

            Button {
                manager.toggleSelectAll(false)
            } label: {
                Label("Deseleziona tutto", systemImage: "circle")
            }
            .disabled(manager.mediaItems.isEmpty)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(manager.statusMessage)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Toggle("Organizza automaticamente per data", isOn: $manager.organizeByDate)

                Picker("", selection: $manager.dateFolderStyle) {
                    ForEach(DateFolderStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .frame(width: 240)
                .disabled(!manager.organizeByDate)
                .labelsHidden()

                Text("Duplicati:")
                    .font(.callout)
                Picker("", selection: $manager.duplicatePolicy) {
                    ForEach(DuplicatePolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .frame(width: 140)
                .labelsHidden()

                Spacer()

                Button {
                    manager.chooseDestinationFolder(window: NSApp.keyWindow)
                } label: {
                    Label(
                        manager.destinationFolder?.lastPathComponent ?? "Scegli cartella…",
                        systemImage: "folder"
                    )
                }
            }

            HStack(spacing: 16) {
                Toggle("Converti HEIC in JPEG", isOn: $manager.convertHEICtoJPEG)
                Toggle("Converti video in H.264", isOn: $manager.convertVideoToH264)
                Toggle("Elimina dall'iPhone dopo la copia", isOn: $manager.deleteFromDeviceAfterCopy)
                Spacer()
            }
            .font(.callout)
            .toggleStyle(.checkbox)

            progressRow
        }
        .padding()
    }

    @ViewBuilder
    private var progressRow: some View {
        HStack {
            if manager.isCopying {
                ProgressView(value: Double(manager.copiedSoFar), total: Double(max(manager.totalToCopy, 1)))
                    .frame(width: 200)
                Text("\(manager.copiedSoFar)/\(manager.totalToCopy)")
                    .font(.caption)
                    .monospacedDigit()

                if manager.isPaused {
                    Button {
                        manager.resumeCopy()
                    } label: {
                        Label("Riprendi", systemImage: "play.fill")
                    }
                } else {
                    Button {
                        manager.pauseCopy()
                    } label: {
                        Label("Pausa", systemImage: "pause.fill")
                    }
                }

                Button(role: .destructive) {
                    manager.cancelCopy()
                } label: {
                    Label("Annulla", systemImage: "xmark.circle")
                }
            } else if manager.hasFailedItems {
                Button {
                    manager.retryFailed()
                } label: {
                    Label("Riprova i file falliti", systemImage: "arrow.clockwise")
                }
            }

            Spacer()

            let selectedCount = manager.mediaItems.filter { $0.isSelected }.count
            Button {
                manager.startCopySelected()
            } label: {
                Label("Copia \(selectedCount) elementi", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 4)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCount == 0 || manager.destinationFolder == nil || manager.isCopying)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DeviceManager())
}
