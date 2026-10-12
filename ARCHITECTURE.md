# Noty architecture

Noty has a native SwiftUI iOS/iPadOS app and a browser companion. The repository version saves user content only on the current device and has no account or cloud backend.

## Layout

- `Noty/NotyApp.swift`: creates the local store, discards legacy local credentials, and handles explicitly opened files.
- `Noty/Core/`: document models, local persistence, on-device handwriting recognition, Word conversion, drawing geometry, and shared design components.
- `Noty/Library/`: notebook/folder library, search, Trash, writing settings, and privacy information.
- `Noty/Editor/`: PencilKit editor, page/text/image objects, whiteboards, study tools, selection clipboard, and local exports.
- `NotyTests/`: native tests with bundled PDF and DOCX fixtures.
- `web/`: browser editor with local IndexedDB storage and manual notebook imports/exports.

## Persistence

`NotyStore` is the authoritative local store. It saves `manifest.json` in `Application Support/Noty` and keeps `manifest.previous.json` for recovery from a damaged manifest. Asset directories contain original imports, source PDFs, drawings, images, and handwriting indexes. Deleted notebooks are packaged in local Trash until restored or permanently removed.

The manifest keeps backward-compatible decoding, including older timestamps and deletion records, so existing local notebooks can reopen. Legacy folder bookmarks are discarded without being resolved. No mutation schedules sync or writes to an external folder.

Audio recording, playback, and export are absent. `NotyDocument` ignores the obsolete recording field when decoding older notebooks or Trash entries, and new saves omit it. Existing local recording files are left untouched. No microphone permission or audio-session code remains.

`NotyLocalStorage` prepares local directories with `isExcludedFromBackup` and removes obsolete account credentials and folder settings from earlier installations. The app's entire Application Support and Documents directories are excluded from system backup, including legacy local export caches outside the current library. It never contacts a server.

## Imports and exports

The app accepts explicitly selected file URLs, copies imports into its sandbox, and never writes back to their original providers. A second copy of an imported original is visible in `Documents/Noty Imports`. Remote URLs passed to the document importer are rejected before reading content.

`LocalOfficeConverter` uses bundled JavaScript and `DOCXPreviewPDFSession` to render DOCX offline, with a local text fallback. The renderer uses an ephemeral WebKit data store. Its Content Security Policy permits embedded images/fonts and inline layout styles, blocks external resources and connections, and its navigation delegate allows only local file navigation.

`NotyExportService` renders PDF/PNG into `Documents/Noty Exports`. The editor reports the saved filename and local Files location. There is no share sheet or writable provider-folder selection. Clipboard writes for page objects, text, and images use `localOnly` to prevent Universal Clipboard transfer.

## UI contracts

`LibraryView(store: NotyStore)` opens `DocumentEditorView(documentID: UUID, store: NotyStore)`. Settings contain writing preferences, local storage information, and Privacy. No account client is constructed at launch or on scene transitions, and no background processing task is registered or permitted.

Page coordinates use each page's persisted canvas size. Legacy pages decode as US Letter portrait (612 × 792 points); resizing preserves ink, text, and images proportionally. Local exports compose original PDF content, drawings, typed text, photos, and covers.

## Validation

The native suite verifies imports, editor geometry, persistence across relaunch, Trash recovery, selection operations, search, and local exports. Local-only regressions verify that a legacy external-folder grant cannot resume mirroring, local directories are excluded from backup, remote imports fail, and the Word renderer blocks external resources while retaining embedded images.

## Browser storage

`web/src/local-library.mjs` stores notebooks, folders, and binary assets in IndexedDB. Each save checks the stored revision in the same transaction to prevent another browser tab from overwriting newer changes. Imports save a notebook and its assets atomically; deletion removes both. Local draft recovery uses localStorage. The editor reads assets through local Blob URLs and exports downloaded notebook ZIPs and PDFs.

The browser companion has no account, remote database, storage service, recording controls, or automatic sync. Legacy notebook imports discard account and recording metadata. Its production Content Security Policy blocks outgoing data connections while allowing local Blob reads. Each browser profile and site origin has an independent library, so users move notebooks by manually downloading and importing files.
