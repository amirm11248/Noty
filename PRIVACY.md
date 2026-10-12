# Noty privacy notice

**Source reviewed:** 2026-10-12

**Maintainer:** [Malik Abdullah Amir](https://github.com/amirm11248)

This technical notice describes the local-only source in this repository and complements the native app's Privacy screen. The project's personal hobby purpose is recorded in [PROJECT_STATUS.md](PROJECT_STATUS.md).

## Local notes and permissions

The native app stores notebooks, handwriting, imported documents, photos, and study cards in its local sandbox. Handwriting recognition and native Word conversion run on the device. Application Support and Documents, including imported originals and exports, are excluded from system backups.

The photo picker shares only images selected by the user. Camera access is requested for document scanning. This version has no audio recording, playback, audio export, or microphone permission. Older notebooks and Trash entries remain readable; obsolete recording metadata is ignored. Existing local recording files are not deleted by this source change.

There are no account, sign-in, cloud-folder, background-upload, or backend-storage features. Older local credentials and folder grants are discarded without contacting their previous providers. Removing source code does not erase previously created accounts or external copies.

## Browser storage

The browser companion saves notebooks, folders, and imported binary files in IndexedDB on the current device. Interface preferences and recoverable unsaved drafts use local browser storage. No account, remote database, file-transfer endpoint, or cloud service is used. A static host may receive ordinary requests to deliver the application files; notes and imported content are not sent to it by this app.

The production browser policy blocks outgoing data connections except local blob reads. Fonts, editor libraries, and PDF/Word tools are bundled with the app. Imported HTML is sanitized. Native Word rendering blocks external resources and connections.

Browser data belongs to that browser and site address. Clearing site data or removing the browser can delete it. Download notebook ZIP backups to local storage before clearing browser data or switching devices. Browser or operating-system backup behavior outside the native app is controlled by those products.

## Retention and deletion

Native and browser Trash retain local notebooks for recovery until the user permanently deletes them. Permanent deletion removes the local notebook package or browser record and its assets. Copies previously exported by the user remain until the user removes them.

PDF/PNG exports in the native app save to On My iPhone/iPad → noty → Noty Exports. Browser backups and text exports use downloads. If a user later moves files through Files or another application, that application controls the destination. Imported documents are copied locally and are not edited at their source.

## Tracking and distribution

The app source contains no advertising, analytics, or remote data collection. Keep personal notes and private logs out of public issues; use [SECURITY.md](SECURITY.md) for private security reports.

This repository notice describes the source. Any distributed app or website needs operator and privacy information matching its actual configuration and delivery channel.
