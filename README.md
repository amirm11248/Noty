# noty

A minimal, offline-first Apple-device notebook for class notes, study sessions, and writing directly on PDFs. Built with SwiftUI, PencilKit, and PDFKit. The app keeps a local editable library, can synchronize that library through a user-selected iCloud Drive/Files folder, and now has a real Supabase-backed Noty account for cross-device workspace discovery. It can also keep rendered PDF copies in a OneDrive folder exposed through Files.

## Open and run

Open `Noty.xcodeproj` in Xcode, choose the **Noty** scheme and an iPhone/iPad simulator or device, then Run. The project targets iOS/iPadOS 18 or later. If you change `project.yml`, run `xcodegen generate` before opening Xcode again. The generated project is already included, so XcodeGen is not needed just to build it.

For installation on a physical iPad, select your Apple team in Xcode under **Signing & Capabilities**. Free Apple Personal Team provisioning expires after seven days; keep the cloud backup enabled and verify the files appear in iCloud Drive before relying on them for recovery.

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
- Record lectures while writing, adjust playback speed, share clips and jump to the page where recording began. Recording stops when you leave the notebook or the app enters the background.
- Use the notebook’s study tools for flashcards and timed focus sessions.
- Scroll continuously through notebook pages. Swipe the page sidebar left to hide it and swipe in from the left edge to show it. Each thumbnail has a three-dot menu with Design, Color and Size flyouts, bookmarks, duplication and moving controls; **Arrange pages** also provides reorder handles. Add pages using the current paper or choose a different design. Deleted documents move to **Trash**, where they can be restored or permanently removed.
- Present a document full-screen with swipe/page navigation, an on-screen laser pointer, hidden controls, and a temporary black-screen mode.
- Export the full document as a **PDF** or the current page as a high-resolution **PNG** from the top-right document menu. Choose **Export selected pages** to select the pages included in a PDF; their notebook order is retained. Exports remain in **On My iPad → noty → Noty Exports**.
- A modern `.docx` is rendered offline to PDF when possible. If its layout cannot be rendered, noty uses a text conversion and tells you that formatting was simplified. It always retains the original file. Legacy `.doc` cannot be converted reliably offline; noty retains it and creates an editable explanation page. For exact legacy Word layout, export a PDF from Word or Pages first.

## Syncing your library

Open **Settings → Sync with Folder** and choose a writable folder in Files. For multi-device use, choose an iCloud Drive folder and select that same folder on each device. New setups use a `Noty Sync` subfolder; existing `Noty Backup` folders remain compatible. Noty stores versioned editable document packages there, merges newer changes into the local library, keeps deletion tombstones, saves after edits, checks again when the app becomes active, and requests iPadOS background-processing retry opportunities.

### Noty account + setup on another device

Noty now has a real account backend using **Supabase Auth + Postgres**. Create an account or sign in under **Settings → Noty Account**. Authentication sessions are stored in the device Keychain, while Postgres stores the account's sync-workspace metadata (currently the iCloud/shared-folder link and folder display name). Row Level Security restricts each account to its own profile row.

After choosing an iCloud Drive sync folder, optionally paste its sharing URL and tap **Save link to my Noty account**. On another iPhone or iPad, sign into the same Noty account: the workspace link is downloaded from the backend automatically. Open the saved link if needed, then choose that folder once in Files. iOS intentionally makes the actual security-scoped Files permission device-local, so no backend can silently transfer that grant between devices.

For your own private notes, prefer a private folder or **People You Choose** sharing. If you deliberately use **Anyone with the link → Can make changes**, treat that URL like a secret because anyone who obtains it can modify the shared folder.

The account now also syncs editable notebooks through the shared Supabase document/folder tables and private Backblaze B2 assets. The Sites companion uses the same account and document format. See `web/README.md` and `SYNC_VALIDATION.md` for the sync contract, implemented web actions and remaining physical-device validation. Install the updated iPad build and let Noty Cloud finish syncing to make existing notebooks and native ink previews available in the browser.

The in-app status confirms when Noty has read or written the selected Files folder. iPadOS and the File Provider control when those changes actually reach iCloud. Before deleting the app or wiping a device, verify the `Noty Sync` (or legacy `Noty Backup`) data is present in Files.

For **OneDrive**, install and sign in to the OneDrive iPad app if your school permits it. In Files, ensure OneDrive appears under **Locations**. Then choose a OneDrive folder in Noty's Settings. This remains a separate PDF mirror for reading and recovery: Noty saves updated annotated PDF copies there after edits and during background retry opportunities. The editable multi-device library uses **Sync with Folder**.


## Development

Run the **NotyTests** target in Xcode. Integration tests exercise PDF and DOCX import, page editing, PDF/PNG export, and editable backup recovery using a local folder as a stand-in for a Files provider. The DOCX renderer bundles offline JavaScript dependencies and license files in `Noty/Core/Resources`.

Cloud execution is still best effort: a `BGProcessingTask` gives iPadOS another opportunity to finish cloud work after Noty leaves the foreground, but the system does not guarantee an exact run time and the Files provider controls the final upload. Keep the iCloud Drive folder selected and check the provider’s status in Files when you need to confirm a backup has reached the cloud.

## Release validation

See [RELEASE_READINESS.md](RELEASE_READINESS.md) for verified checks and the remaining device and App Store submission steps. [FEATURE_STATUS.md](FEATURE_STATUS.md) records the implemented features and remaining differences from Goodnotes. The browser preview mirrors the native iPad app; it is not a separate web editor.
