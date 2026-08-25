//
//  BananaTransferApp.swift
//  BananaTransfer
//
//  Entry point dell'app. Crea il DeviceManager una sola volta e lo
//  inietta come @StateObject in ContentView.
//

import SwiftUI

@main
struct BananaTransferApp: App {

    @StateObject private var deviceManager = DeviceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceManager)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
    }
}
