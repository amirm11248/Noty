# Noty release readiness

Updated 2026-10-12 for the local-only repository version.

## Implemented

- Notebook/folder library, PDF/DOCX imports, PencilKit writing, text/photo objects, search, whiteboards, study tools, presentation, and local Trash recovery.
- PDF/PNG export directly to On My iPhone/iPad → noty → Noty Exports.
- Existing local library compatibility; legacy account credentials and folder grants discarded without contacting a backend.
- No accounts, iCloud/CloudKit integration, cloud sync, writable cloud-folder selection, or background uploads. The legacy iCloud folder-sync implementation and tests are removed; the old local bookmark is only discarded during upgrades.
- Application Support and Documents directories excluded from system backup, including legacy local export caches; device-local page-object, text, and image clipboard writes.
- Offline Word rendering with remote resources and connections blocked.
- In-app privacy information and a privacy manifest declaring no collected user data.
- Audio recording, playback, audio export, and microphone permission removed. Old notebooks and Trash entries ignore obsolete recording metadata and remain readable.
- Browser companion uses IndexedDB for notebooks, folders, and assets, with local draft recovery and manual file import/export. Its production Content Security Policy blocks outgoing data connections.

## Validation

Verified on 2026-10-12 with Xcode 27.0:

- Unsigned Release build for a generic iOS device succeeded (`CODE_SIGNING_ALLOWED=NO`).
- Debug app and `NotyTests` bundle compiled successfully for a generic iOS device with `build-for-testing`.
- The legacy recording-metadata compatibility regression passed on macOS using the app's actual model source: one test, zero failures. Older notebooks and Trash entries decode successfully, and new saves omit recording metadata.
- Source, configuration, and Release executable checks found no backend clients, endpoints, cloud sync, background-upload configuration, or audio recording/playback code. The built app has no microphone usage description. `git diff --check` passed.
- Browser production build and all 12 browser tests passed, including local binary persistence, concurrent-tab save conflicts, atomic imports, asset deletion, legacy metadata cleanup, and local drafts.
- Browser save/reload/reopen was checked against the production build without a simulator.
- Compatible browser dependency updates address the reported Vite and fflate advisories. `npm audit` still reports three moderate findings through Mammoth's argparse/sprintf-js CLI dependencies; its suggested automatic fix would downgrade Mammoth incompatibly.

The full native iOS suite was not executed: the Mac's simulator was unavailable, and the user requested that it not be used. Build success confirms compilation, not app runtime behavior. Run `NotyTests` on a working device before distribution; the suite covers editing, import, local persistence, exports, Trash, and local-only regressions. Earlier cloud-version test results are not evidence for this version.

## Before distribution

1. Test on a physical iPad: Apple Pencil latency, Split View, text focus, lasso selection, undo, zoom, photos, imports, local export, and Trash recovery.
2. Verify local files under On My iPhone/iPad, relaunch persistence, and upgrading from an older installation with saved local notebooks. Keep local copies before uninstalling; this version has no cloud recovery.
3. Configure signing and complete any required distribution metadata, support contact, privacy-policy URL, screenshots, and platform validation.

## Product limits

- Legacy `.doc` layout cannot be converted reliably offline; the original is retained with an explanation page. Complex DOCX files may use a simplified text fallback.
- Presentation runs in the app window. A separate external-display audience window is not implemented.
- The editable library belongs to this device. There is no multi-device sync, collaboration, or account-based recovery.
- Moving an exported file using Files or another app is controlled by that app and the user.
