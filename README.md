# noty

Personal hobby project by [Malik Abdullah Amir](https://github.com/amirm11248), currently developed for learning and personal use without monetization. Original code and documentation are licensed under [MIT](LICENSE). See [PROJECT_STATUS.md](PROJECT_STATUS.md) for the current purpose.

A local-only Apple-device notebook for class notes, study sessions, and writing directly on PDFs. Built with SwiftUI, PencilKit, and PDFKit. This repository version has no account system, backend connection, cloud storage, or automatic sync. Notebooks, photos, and study cards stay on the device.
## Open and run

Open `Noty.xcodeproj` in Xcode, choose the **Noty** scheme and an iPhone/iPad simulator or device, then Run. The project targets iOS/iPadOS 18 or later. If you change `project.yml`, run `xcodegen generate` before opening Xcode again. The generated project is already included, so XcodeGen is not needed just to build it.

For installation on a physical device, select your Apple team in Xcode under **Signing & Capabilities**. Keep your own local exports before uninstalling Noty or erasing the device; this version has no cloud recovery.

## Using noty

- Create a **notebook** by choosing its cover and paper first. Its cover is page 1 and is included in exports. Paper options include blank, ruled, narrow ruled, grid, small grid, dotted, Cornell, weekly/daily planners, music and checklists. Each page can use its own color, paper size (A4/A5/Letter/Legal/Square/4:3/16:9), and portrait or landscape orientation.
- Import **PDF** or **DOCX** from Files, or open a shared file from another app. Draw over imported pages with Apple Pencil or touch, pinch-zoom the page, and add movable rich-text boxes.
- Add photos from Photos, Files or clipboard as page objects, then move, resize, rotate, crop, copy or delete them. Ink remains on top of images in exported documents.
- Use text boxes with font, color, alignment, lists and checklists. Undo and redo work for ink, text and photos.
- Organize notebooks in large customizable folder cards, with colors, textures, subject symbols and optional photos. The root library shows unfiled notebooks; open a folder to see its contents.
- The notebook header contains Back and a top-right three-dot menu for search, adding/arranging pages, presentation and export. The writing toolbar follows light or dark appearance.
- Choose **New whiteboard** in Home for an infinite canvas. Pan and pinch to zoom; the board grows toward every edge and saves its viewing position. Pen, text, photo and lasso tools work on the board, and exports crop to your content.
- Drag anywhere on the compact writing toolbar to dock it at the top, bottom, left or right; a dark preview shows the destination before you release. Tap the selected pen, highlighter, eraser, lasso, text or pan tool again for its settings. Photos has an insertion and editing popover. Pinch to zoom, or use Fit page in the three-dot menu. Apple Pencil is the default drawing input; finger drawing is optional.
- Use the three-dot menu to show the native ruler or toggle **Draw and hold to perfect shapes**. Pause for a moment at the end of a line, rectangle, triangle or ellipse, before lifting, to replace it with a precise shape. Undo reverses the correction.
- Open **Search library & notebooks** in the sidebar to find titles, typed notes, handwriting and PDF text. Each result opens its matching page. Handwriting is recognized automatically on-device after edits; unfinished indexing resumes when you reopen the app or search.
- Select ink, text and photos together with a freehand or rectangular lasso. Move or resize the group, cut/copy/paste it between pages or notebooks, duplicate or delete it, and undo the entire action once. Tap the lasso again to choose selection filters.
- Use the notebook’s study tools for flashcards and timed focus sessions.
- Scroll continuously through notebook pages. Swipe the page sidebar left to hide it and swipe in from the left edge to show it. Each thumbnail has a three-dot menu with Design, Color and Size flyouts, bookmarks, duplication and moving controls; **Arrange pages** also provides reorder handles. Add pages using the current paper or choose a different design. Deleted documents move to **Trash**, where they can be restored or permanently removed.
- Present a document full-screen with swipe/page navigation, an on-screen laser pointer, hidden controls, and a temporary black-screen mode.
- Export the full document as a **PDF** or the current page as a high-resolution **PNG** from the top-right document menu. Choose **Export selected pages** to select the pages included in a PDF; their notebook order is retained. Exports remain in **On My iPad → noty → Noty Exports**.
- A modern `.docx` is rendered offline to PDF when possible. If its layout cannot be rendered, noty uses a text conversion and tells you that formatting was simplified. It always retains the original file. Legacy `.doc` cannot be converted reliably offline; noty retains it and creates an editable explanation page. For exact legacy Word layout, export a PDF from Word or Pages first.

## Local storage and privacy

- The editable library lives in the app's local `Application Support/Noty` directory. Existing local notebooks continue to load after upgrading.
- Imported originals are also available in **Files → On My iPhone/iPad → noty → Noty Imports**.
- PDF and PNG exports are saved directly in **Files → On My iPhone/iPad → noty → Noty Exports**. The app confirms the filename after saving; it does not open a sharing or cloud-destination picker.
- The app's Application Support and Documents directories are excluded from system backups, including older local export caches. Copy any files you want to keep to your own local storage before removing the app.
- There are no sign-in, signup, account deletion, cloud-folder, or background-upload features, and no backend credentials or deployment files are needed.
- iCloud folder sync and CloudKit integration are removed. Noty cannot select an iCloud destination or save changes to it; local app files are excluded from system backups.
- Audio recording, playback, and audio export are removed, and the app does not request microphone access. Older notebooks and Trash entries remain readable; their obsolete recording metadata is ignored. Existing local recording files are not deleted by this change.
- Old local account credentials and folder grants are discarded on upgrade without contacting their former services. Existing external copies are left in place.
- Word conversion runs with bundled resources, an ephemeral WebKit data store, and a policy that blocks remote resources and network requests. Copied page objects, text, and images use a device-local clipboard.
- The app has no advertising, analytics, or remote data collection. Camera and photo access are used only for the features you choose.

You can import files you explicitly select through Files or Photos. Noty saves the imported copy locally and never writes changes back to the source provider. If you subsequently move an export through Files or another app, that app controls its destination.

## Development

Run the **NotyTests** target in Xcode. Integration tests exercise PDF and DOCX import, page editing, local persistence, Trash recovery, and PDF/PNG export. Local-only regression tests cover upgrades with legacy folder grants and recording metadata, backup exclusion, remote import rejection, and blocked external Word resources. The DOCX renderer bundles offline JavaScript dependencies and license files in `Noty/Core/Resources`.

## Release validation

See [RELEASE_READINESS.md](RELEASE_READINESS.md) for verified checks and the remaining device and App Store submission steps. [FEATURE_STATUS.md](FEATURE_STATUS.md) records the implemented features and remaining differences from Goodnotes. The separate browser companion also saves locally, with no accounts or backend. See [web/README.md](web/README.md) for setup and local backup downloads.
