# noty

A quiet, iPad-first notebook for class notes, books, and writing directly on PDFs. Built with SwiftUI, PencilKit, and PDFKit. The app keeps its editable library on the iPad and can copy it to a folder you choose in iCloud Drive. It can also keep rendered PDF copies in a OneDrive folder exposed through Files.

## Open and run

Open `Noty.xcodeproj` in Xcode, choose the **Noty** scheme and an iPad simulator or your iPad, then Run. The project targets iPadOS 18 or later. If you change `project.yml`, run `xcodegen generate` before opening Xcode again. The generated project is already included, so XcodeGen is not needed just to build it.

For installation on a physical iPad, select your Apple team in Xcode under **Signing & Capabilities**. Free Apple Personal Team provisioning expires after seven days; keep the cloud backup enabled and verify the files appear in iCloud Drive before relying on them for recovery.

## Using noty

- Create **notes** or **books**, add blank, ruled, grid, or dotted pages, bookmark important pages, and organize documents in nested folders.
- Import **PDF** or **DOCX** from Files, or open a shared file from another app. Draw over imported pages with Apple Pencil or touch, pinch-zoom the page, and add movable rich-text boxes.
- Add photos from the iPad photo library as page objects, then move, resize, rotate, or delete them. Ink remains on top of images in exported documents.
- Reorder, duplicate, bookmark, or delete pages in the thumbnail rail. Deleted documents move to **Trash**, where they can be restored or permanently removed.
- Export the full document as a **PDF** or the current page as a high-resolution **PNG** from the editor’s share button. Exports remain in **On My iPad → noty → Noty Exports**.
- A modern `.docx` is rendered offline to PDF when possible. If its layout cannot be rendered, noty uses a text conversion and tells you that formatting was simplified. It always retains the original file. Legacy `.doc` cannot be converted reliably offline; noty retains it and creates an editable explanation page. For exact legacy Word layout, export a PDF from Word or Pages first.

## Syncing your library

Open **Settings → Sync with Folder** and choose a writable folder in Files. For multi-device use, choose an iCloud Drive folder and select that same folder on each device. New setups use a `Noty Sync` subfolder; existing `Noty Backup` folders remain compatible. Noty stores versioned editable document packages there, merges newer changes into the local library, keeps deletion tombstones, saves after edits, checks again when the app becomes active, and requests iPadOS background-processing retry opportunities.

### Smooth setup on your other Apple devices

For a shared iCloud Drive folder, configure the folder in Files as **Anyone with the link → Can make changes**, copy its sharing link, and paste it once into **Settings → Sync with Folder → Shared folder link**. Noty stores only that discovery link as a synchronizable iCloud Keychain item. Apple documents `kSecAttrSynchronizable` as synchronizing keychain items to the user's other devices through iCloud.

On another iPhone or iPad using the same Apple Account with iCloud Keychain enabled, open Noty Settings and tap **Check iCloud Keychain for a link**. The saved link can appear without typing or remembering it. Tap **Open saved shared-folder link** to open/join the folder, then **Choose sync folder** and select it once in Files. iOS intentionally makes the actual security-scoped Files permission device-local, so Noty cannot silently transfer that grant between devices.

No Noty account or server is required for this same-Apple-Account setup, and the backend never receives your notebooks because there is no Noty backend in this path. If another person uses a different Apple Account, send them the folder's normal iCloud sharing link; after joining it they still select the folder once in Noty.

The in-app status confirms when Noty has read or written the selected Files folder. iPadOS and the File Provider control when those changes actually reach iCloud. Before deleting the app or wiping a device, verify the `Noty Sync` (or legacy `Noty Backup`) data is present in Files.

For **OneDrive**, install and sign in to the OneDrive iPad app if your school permits it. In Files, ensure OneDrive appears under **Locations**. Then choose a OneDrive folder in Noty's Settings. This remains a separate PDF mirror for reading and recovery: Noty saves updated annotated PDF copies there after edits and during background retry opportunities. The editable multi-device library uses **Sync with Folder**.


## Development

Run the **NotyTests** target in Xcode. Integration tests exercise PDF and DOCX import, page editing, PDF/PNG export, and editable backup recovery using a local folder as a stand-in for a Files provider. The DOCX renderer bundles offline JavaScript dependencies and license files in `Noty/Core/Resources`.

Cloud execution is still best effort: a `BGProcessingTask` gives iPadOS another opportunity to finish cloud work after Noty leaves the foreground, but the system does not guarantee an exact run time and the Files provider controls the final upload. Keep the iCloud Drive folder selected and check the provider’s status in Files when you need to confirm a backup has reached the cloud.
