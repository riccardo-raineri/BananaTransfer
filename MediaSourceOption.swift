//
//  MediaSourceOption.swift
//  BananaTransfer
//
//  Una voce selezionabile nel menu "sorgente": può essere la fotocamera/
//  iPhone connessa via cavo, oppure un volume USB/SD montato come disco.
//

import Foundation

struct MediaSourceOption: Identifiable, Hashable {

    enum Kind: Hashable {
        case camera
        case volume
    }

    /// Per la fotocamera è un id fisso ("camera"); per un volume è il suo
    /// path di mount (stabile per tutta la durata in cui resta collegato).
    let id: String
    let name: String
    let systemImage: String
    let kind: Kind
}
