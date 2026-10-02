# Feature status

Audit date: 2026-10-02

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
- [x] Active-tool popovers for pen type/width/color, highlighter, pixel/whole-stroke eraser, lasso filters, text, photos and navigation
- [x] PencilKit ruler from the notebook’s three-dot menu
- [x] Freehand/rectangular lasso selects handwriting, text boxes and photos together, with content filters, live group movement/resizing, cut/copy/paste/duplicate/delete and one-step undo
- [x] Undo / redo for ink, text boxes, photo insertion, cropping, positioning and deletion
- [x] Manual straight-line, rectangle and ellipse insertion
- [x] Text boxes with move/resize/edit, font family, size, bold, italic, underline, color and alignment
- [x] Automatic on-device handwriting OCR with versioned drawing fingerprints, restart recovery, ink normalization and stale-result invalidation
- [x] Sidebar search across notebook names, folders, typed text, handwriting and imported PDF text; results open the matching page
- [x] Continuous scrolling across mixed-size pages with separate canvas/undo state
- [x] Swipe to hide/show the notebook page sidebar
- [x] Add, delete, duplicate and reorder pages through drag/drop and an Arrange pages sheet
- [x] Three-dot menu on each thumbnail with collapsed Design, Color and Size flyouts
- [x] Page thumbnails
- [x] Pinch/page zoom from 65% to 300%
- [x] Insert photos from Photos, Files or clipboard; move, resize, rotate, copy and non-destructively crop
- [x] Named page bookmarks with quick-jump menu
- [x] Blank, regular/narrow ruled, regular/small grid, dotted and Cornell paper
- [x] Per-page paper colors with presets and a custom color picker
- [x] Per-page A4, A5, US Letter, US Legal, square, 4:3 and 16:9 sizes
- [x] Per-page portrait / landscape orientation with content-preserving resize
- [x] Imported PDF pages retain their actual dimensions and displayed rotation through editing, duplication and export
- [x] Notes and book documents
- [x] Nested folders with large customizable cards, colors, textures, symbols and photos
- [x] Folder navigation keeps filed notebooks inside their folders; recents, favorites and search can find them across the library
- [x] Drag notebooks into folder cards, or use Move to folder
- [x] Recents, document favorites, duplication, sorting, shelf/list views
- [x] Home sidebar with a lowercase noty wordmark, minimal headings and adaptive white/neutral-gray surfaces
- [x] Notebook creation chooses cover and paper before opening the notebook
- [x] Actual cover as page 1, included in thumbnails, presentation and PDF/PNG exports; legacy notebooks migrate when opened
- [x] Custom photo covers; cover changes and notebook title stay in sync
- [x] New pages use the current writing paper or open the paper chooser
- [x] Minimal notebook header with Back and a top-right document menu
- [x] Writing toolbar follows light/dark appearance
- [x] Infinite whiteboards with automatic growth toward all edges, saved viewport, world-coordinate undo and content-cropped PDF/PNG exports
- [x] Compact floating toolbar dragged from any point, with a dark preview and persisted docking on the top, bottom, left or right
- [x] Draw and hold to perfect lines, rotated rectangles, triangles and ellipses; optional toggle and undo
- [x] Pencil-only drawing by default, optional finger drawing, dedicated pan tool
- [x] Weekly/daily planner, Cornell, music and checklist templates with matching export geometry
- [x] Editable study cards, shuffled review sessions and a focus timer
- [x] Lecture recording, playback speed, seeking, sharing and links to the starting page
- [x] On-device privacy information and privacy manifest
- [x] Adaptive launch-screen configuration and a minimal frosted notebook App Store icon, encoded as opaque RGB
- [x] Password-confirmed account deletion, backed by a deployed authenticated server function
- [x] Restorable in-app Trash with permanent-delete / empty-trash actions
- [x] Full annotated PDF export and selected-page PDF export in notebook order
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

- [ ] Dashed/dotted drawing strokes
- [ ] Scribble-to-erase gesture
- [ ] Dedicated Goodnotes-style zoom-writing window (normal pinch/page zoom is implemented)
- [ ] Smart Ink-style handwriting reflow/editing and handwriting spell correction
- [ ] User-imported reusable paper templates (built-in Cornell, planners and music paper are implemented)
- [ ] Automatic document outline and internal page-link objects (named bookmarks and per-notebook search are implemented)
- [ ] Password-protected notebooks
- [ ] Semantic PDF text selection/highlight annotations; current highlighter is PencilKit ink
- [ ] Flowing rich-text paragraphs with independent per-paragraph styles (text boxes support bullet, numbered and checklist insertion)
- [ ] Stickers, reusable elements, GIFs and GIPHY (image/photo objects are implemented)
- [ ] Dedicated second-screen / external-display audience window (the in-app presenter, laser pointer and hide-screen mode are implemented)
- [ ] Flowing Notion/Docs-style text documents
- [ ] Collaboration and shared live editing
- [ ] Marketplace/template store

## Validation on 2026-10-02

- The editor update passed a full 41-test simulator run and eight focused follow-up tests covering continuous-page geometry, whiteboard growth and persistence, selected-page exports, cropped whiteboard exports and undo after canvas expansion. Browser simulator checks cover light-mode styling, page flyout menus, sidebar swipes and the selected-page share flow.
- All 29 native integration tests pass for PDF/DOCX import, retained originals, ink/text/image persistence, exports, trash recovery, cover migration, folder customization, study cards, cropping, rotated photo orientation, undo, editable backup recovery and OneDrive PDF mirroring. A native text-input test verifies focus, Unicode insertion and underline formatting. New lasso tests cover mixed selections, filters, rotated-photo geometry, erased ink gaps, pressure/path preservation, proportional text spacing, grouped undo and cross-document paste with original photo bytes and failure cleanup. Debug build/launch and an unsigned arm64 iOS Release archive succeed; an earlier unsigned Release simulator build also passed.
- The backup timestamp format now preserves millisecond revisions, with backward decoding of older ISO timestamps; unchanged sync reuses a snapshot.
- Word conversion uses a printed-page-sized viewport independent of the app's Split View width and preserves physical paper dimensions. Imported lecture PDFs retain custom sizes and displayed rotation.
- Account deletion has eight passing handler tests covering authentication, password confirmation, identity matching, session revocation and failures. No real user's account was deleted for testing.
- Physical Apple Pencil feel, microphone interruptions, actual cloud-provider uploads and signed-device installation require device checks before public release.

## CI

`.github/workflows/ios-ci.yml` builds the iPad app target and runs the native integration suite on GitHub Actions. Cloud/provider behavior still needs physical-iPad testing because simulator/local-folder tests cannot reproduce every iCloud Drive or OneDrive File Provider state.
