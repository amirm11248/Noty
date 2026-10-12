# Noty browser companion

A local-only browser notebook. There is no account setup, cloud sync, Supabase client, or Backblaze backend. Audio recording, audio playback, and audio export are absent.

## Run locally

```sh
npm ci
npm run dev
```

Open the local address printed by Vite. The app needs no service credentials or environment variables. `npm run build` creates a static application in `dist/`; `npm test` runs the local storage and library-import regressions.

## Storage and backups

Notebooks, folders, PDFs, drawings, photos, and imported originals save in this browser's IndexedDB. Unsaved editing drafts and appearance preferences use local browser storage. Saving waits for the local transaction to complete, and conflicting edits in another tab cannot overwrite a newer saved revision.

Use the document menu to download a notebook ZIP backup, text notes, or print/save typed notes as PDF. Import local PDF, DOCX, text, Markdown, HTML, images, notebook ZIPs, or an existing local library folder. Files are copied into local browser storage; the original source is not edited. Notebook and asset imports commit together to avoid partial imports.

Different browsers and site addresses have separate libraries. Download local backups before clearing site data, removing the browser, or changing devices. The native app and browser companion do not automatically exchange files. Existing local library snapshots can be imported manually; this does not enable a folder-sync service.

## Privacy

The production Content Security Policy blocks outgoing data connections except local blob reads. Fonts and conversion tools are bundled. There are no authentication requests, signed upload URLs, remote file storage, or analytics. A static host only serves application assets; notebook content is not sent to it by this app. See [PRIVACY.md](../PRIVACY.md).
