<img width="500" height="500" alt="BananaTransfer_icon_convertito" src="https://github.com/user-attachments/assets/d63277c2-80b5-4280-bf0c-c2a1f36fe99f" />

Windows: coming soon

# 🍌 BananaTransfer

**BananaTransfer** è un'applicazione desktop moderna sviluppata in Swift per sistemi macOS. Il software è progettato specificamente per facilitare l'importazione, la classificazione e il backup locale di file multimediali da dispositivi portatili (come iPhone, iPad o dispositivi MTP.

---

## 🚀 Funzionalità Principali

* **Filtri e Selezione Rapida**: L'interfaccia consente di filtrare la visualizzazione dei contenuti (Tutti, 📷 Foto, 🎥 Video, 🎞️ RAW) e di selezionare o deselezionare tutti gli elementi con un solo clic.
* **Organizzazione per Data**: Permette di suddividere i file esportati in sottocartelle ordinate in modo automatico (formato giornaliero `AAAA-MM-DD` o mensile `AAAA/MM`).
* **Gestione dei Duplicati e Integrità**: Offre criteri personalizzabili per la gestione dei file duplicati (Salta, Rinomina automaticamente o Sovrascrivi) e supporta la verifica dell'integrità tramite SHA-256.
* **Controllo Completo del Trasferimento**: Include comandi di **Avvio**, **Pausa**, **Riprendi** e **Annulla**, affiancati da una barra di avanzamento globale e da un registro delle operazioni (Log) in tempo reale.



# 🍌 BananaTransfer

Applicazione nativa macOS per trasferire foto e video da iPhone (o da schede SD/USB) a un hard disk esterno o a qualsiasi cartella del Mac, in modo affidabile e organizzato.

## 📸 Sorgenti supportate

- **iPhone via cavo USB** — lettura diretta tramite ImageCaptureCore, senza passare da iCloud o dalla libreria Foto.
- **Volumi USB / schede SD / dischi esterni** — rilevati automaticamente non appena montati, letti come normali file system.
- **Menu a tendina** per passare da una sorgente all'altra.

## 🖼️ Griglia e selezione

- Anteprime di foto e video con caricamento progressivo.
- Selezione singola o multipla, con conteggio in tempo reale degli elementi scelti.
- Filtro per tipo: Tutti / Foto / Video / RAW,
- Ordinamento automatico per data di scatto (più recenti in cima).

## 📁 Organizzazione dei file

- Scelta libera della cartella di destinazione.
- Creazione automatica di sottocartelle per data: **per giorno** (`2026-08-22`) o **per anno/mese** (`2026/2026-08`).
- Gestione dei duplicati:
  - **Salta** — non ricopia se il file esiste già,
  - **Rinomina** — copia comunque, aggiungendo un suffisso numerico,
  - **Sovrascrivi** — sostituisce il file esistente.

## ✅ Affidabilità e verifica

- Controllo della dimensione dopo ogni copia (rileva trasferimenti troncati).
- Calcolo e registrazione dell'hash **SHA-256** di ogni file copiato.
- **Registro CSV persistente** (`BananaTransfer-log.csv`) salvato nella cartella di destinazione, con data/ora, esito, dimensione e hash di ogni operazione.
- Pannello di **log in tempo reale** nell'app.
- I file vengono eliminati dalla sorgente (se richiesto) **solo dopo** che la copia è stata verificata con successo.

## ⏯️ Controllo del trasferimento

- Barra di avanzamento globale e per singolo file.
- **Pausa e ripresa** del trasferimento in qualsiasi momento.
- **Annullamento** con gestione pulita degli elementi già in coda.
- **Riprova automatica** dei soli file falliti, senza dover rifare tutto da capo.
- Riepilogo finale con conteggio di copiati / saltati / falliti.

## 🔍 Verifica libreria esistente

- Scansione di una cartella già esistente sul Mac (per nome file + dimensione) per individuare foto/video già trasferiti in passato.
- Deselezione automatica degli elementi già presenti, con badge visivo "Già presente" nella griglia.
- Popup di riepilogo con l'esito della scansione.

## 🔄 Conversioni opzionali

- **HEIC → JPEG** per la massima compatibilità.
- **Video HEVC → H.264** (1920×1080).
- Le conversioni partono solo dopo che il file originale è stato copiato e verificato con successo.

## 🎨 Interfaccia

- Tema chiaro e scuro.
