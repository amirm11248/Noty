# Feature status

Audit date: 2026-10-12

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
- [x] On-device privacy information and privacy manifest
- [x] Adaptive launch-screen configuration and a minimal frosted notebook App Store icon, encoded as opaque RGB
- [x] Restorable in-app Trash with permanent-delete / empty-trash actions
- [x] Full annotated PDF export and selected-page PDF export in notebook order
- [x] High-resolution current-page PNG export
- [x] Full-screen presenter view with swipe/page controls, laser pointer, hide-screen mode and clean audience chrome

## Local-only repository version

- [x] Local editable library, assets, and study cards
- [x] Existing local manifest and Trash compatibility
- [x] Local PDF/PNG exports in On My iPhone/iPad → noty → Noty Exports
- [x] Library, originals, and exports excluded from system backups
- [x] Device-local clipboard writes
- [x] Offline Word conversion with external resources and network connections blocked
- [x] Legacy credentials and folder grants removed locally during upgrade
- [x] Accounts, cloud-folder mirroring, background upload tasks, and backend deployment files removed
- [x] Audio recording, playback, audio export, and microphone permission removed; older notebook and Trash metadata remains readable

Cloud storage, account creation, automatic sync, and server-side user data storage are outside the scope of this repository version.

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

## Validation

The native suite covers PDF/DOCX import, retained originals, ink/text/image persistence, exports, Trash recovery, cover migration, folder customization, study cards, cropping, rotated photo orientation, undo, whiteboards, lasso selections, handwriting, and typed/PDF library search. Local-only regressions cover legacy folder grants and recording metadata, local PDF/PNG output, backup exclusion, remote URL rejection, and external Word resources. See `RELEASE_READINESS.md` for which checks have been run on this version.

Physical Apple Pencil feel, camera behavior, and signed-device installation still require device checks before public release.

## CI

`.github/workflows/ios-ci.yml` builds the iPad app target and runs the native integration suite on GitHub Actions. No runtime backend setup or service credentials are required.
