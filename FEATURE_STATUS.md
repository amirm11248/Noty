# Feature status

Audit date: 2026-09-28

This file tracks the gap between the current native iPad app and the larger Goodnotes-style wishlist. A checked item means there is a real implementation in the app, not only a button or placeholder.

## Core workflow

- [x] Native iOS/iPadOS 18 SwiftUI app for iPhone and iPad
- [x] PDF import from Files / share-open flow
- [x] Modern DOCX import with an offline rich-layout renderer and text fallback
- [x] Original imported Office file retained with the document package
- [ ] Faithful legacy `.doc` rendering. The original is retained, but exact offline conversion is not available.
- [x] PencilKit handwriting over blank/template/PDF pages
- [x] Ball pen, fountain pen, brush, pencil and highlighter
- [x] Pen width, opacity, custom colors and reusable color presets
- [x] PencilKit eraser/lasso/ruler through the native tool picker
- [x] Undo / redo
- [x] Manual straight-line, rectangle and ellipse insertion
- [x] Text boxes with move/resize/edit, font family, size, bold, italic, underline, color and alignment
- [x] On-device handwriting OCR, searchable OCR sidecars and handwriting-to-text
- [x] Search document names, folders, typed text, OCR handwriting and imported PDF text
- [x] Add, delete, duplicate and reorder pages
- [x] Page thumbnails
- [x] Pinch/page zoom from 65% to 300%
- [x] Insert photos as movable/resizable/rotatable page objects
- [x] Page bookmarks with quick-jump menu
- [x] Blank, regular/narrow ruled, regular/small grid, dotted and Cornell paper
- [x] Per-page paper colors with presets and a custom color picker
- [x] Per-page A4, A5, US Letter, US Legal, square, 4:3 and 16:9 sizes
- [x] Per-page portrait / landscape orientation with content-preserving resize
- [x] Notes and book documents
- [x] Nested folders, recents, document favorites and sorting
- [x] Restorable in-app Trash with permanent-delete / empty-trash actions
- [x] Full annotated PDF export
- [x] High-resolution current-page PNG export
- [x] Full-screen presenter view with swipe/page controls, laser pointer, hide-screen mode and clean audience chrome

## Cloud durability

### Sync with Folder editable library

- [x] User selects a writable folder through the iOS Files picker
- [x] New setups use a `Noty Sync` subfolder
- [x] Existing `Noty Backup` folders remain readable for migration compatibility
- [x] Directory permission is persisted with the iOS directory-bookmark flow
- [x] Stale bookmarks are refreshed when possible
- [x] Bidirectional manifest merge for folders/documents/deletions
- [x] Versioned editable snapshots include manifest, imported PDFs/originals and drawing assets
- [x] Tombstones prevent intentionally deleted documents from returning
- [x] Foreground edit debounce and foreground/scene-transition sync
- [x] `BGProcessingTask` retry scheduling
- [x] Real Noty email/password accounts through Supabase Auth
- [x] Auth session persisted securely in the device Keychain
- [x] Postgres-backed per-user sync profile for iCloud/shared-folder link + folder name
- [x] Row Level Security restricts each profile to its signed-in user
- [x] A second device can recover workspace metadata after signing into the same Noty account
- [x] Recovery and legacy-folder regression tests
- [ ] Zero-tap Files permission transfer between devices — intentionally impossible with iOS security-scoped folder access
- [ ] Same-document collaborative merge. Current document conflicts use document-level timestamp resolution rather than Google-Docs-style operation merging.

iOS requires every device to approve external Files-folder access once. The Noty backend can synchronize discovery metadata, but Apple does not allow the security-scoped directory grant itself to be copied between devices.


### OneDrive PDF mirror

- [x] Works with the official OneDrive Files provider without storing Microsoft credentials
- [x] User-selected writable OneDrive folder survives relaunch through the iOS directory-bookmark flow
- [x] Renders the latest annotated document to PDF
- [x] Skips unchanged documents
- [x] Handles renamed documents
- [x] Keeps previously exported PDFs after a Noty document is deleted as a recovery copy
- [x] Foreground edit debounce and foreground/scene-transition sync
- [x] `BGProcessingTask` retry opportunities
- [x] Relaunch-persistence regression test

This is intentionally Files-provider based rather than Microsoft Graph OAuth. That avoids requiring an Azure application ID and school-tenant consent. The OneDrive provider and iPadOS control the eventual network upload.

## Cross-platform backend roadmap

- [x] Cross-platform Noty account identity
- [x] Backend workspace metadata
- [ ] Web document replica / Supabase Storage layer. iCloud Drive links alone do not expose Noty's editable package format as a general browser API.
- [ ] Web editor/client using the same Noty account

## Still missing for full Goodnotes-level parity

These are not implemented and should not be advertised as finished:

- [ ] Automatic shape recognition
- [ ] Dashed/dotted drawing strokes
- [ ] Scribble-to-erase gesture
- [ ] Dedicated Goodnotes-style zoom-writing window (normal pinch/page zoom is implemented)
- [ ] Smart Ink-style handwriting reflow/editing and handwriting spell correction
- [ ] Notebook covers and custom covers
- [ ] Cornell, planner, music and user-imported templates
- [ ] Document outline / table of contents and internal page links (page bookmarks are implemented)
- [ ] Password-protected notebooks
- [ ] Semantic PDF text selection/highlight annotations; current highlighter is PencilKit ink
- [ ] Paragraph/list formatting beyond the implemented font family, bold, italic, underline, color and alignment controls
- [ ] Stickers, reusable elements, GIFs and GIPHY (image/photo objects are implemented)
- [ ] Dedicated second-screen / external-display audience window (the in-app presenter, laser pointer and hide-screen mode are implemented)
- [ ] Infinite whiteboards
- [ ] Flowing Notion/Docs-style text documents
- [ ] Collaboration and shared live editing
- [ ] Marketplace/template store

## CI

`.github/workflows/ios-ci.yml` builds the iPad app target and compiles the unit-test bundle on GitHub Actions. Cloud/provider behavior still needs physical-iPad testing because simulator/local-folder tests cannot reproduce every iCloud Drive or OneDrive File Provider state.
