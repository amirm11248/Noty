# noty

A quiet, iPad-first notebook for class notes, books, and writing directly on PDFs. Built with SwiftUI, PencilKit, and PDFKit. The app keeps its editable library on the iPad and can copy it to a folder you choose in iCloud Drive. It can also keep rendered PDF copies in a OneDrive folder exposed through Files.

## Open and run

Open `Noty.xcodeproj` in Xcode, choose the **Noty** scheme and an iPad simulator or your iPad, then Run. The project targets iPadOS 18 or later. If you change `project.yml`, run `xcodegen generate` before opening Xcode again. The generated project is already included, so XcodeGen is not needed just to build it.

For installation on a physical iPad, select your Apple team in Xcode under **Signing & Capabilities**. Free Apple Personal Team provisioning expires after seven days; keep the cloud backup enabled and verify the files appear in iCloud Drive before relying on them for recovery.

## Using noty

- Create **notes** or **books**, add blank, ruled, grid, or dotted pages, and organize documents in nested folders.
- Import **PDF** or **DOCX** from Files, or open a shared file from another app. Draw over imported pages with Apple Pencil or touch and add movable text boxes. Reorder or delete pages in the thumbnail rail.
- Export the full document as a **PDF** or the current page as a high-resolution **PNG** from the editor’s share button. Exports remain in **On My iPad → noty → Noty Exports**.
- A modern `.docx` is rendered offline to PDF when possible. If its layout cannot be rendered, noty uses a text conversion and tells you that formatting was simplified. It always retains the original file. Legacy `.doc` cannot be converted reliably offline; noty retains it and creates an editable explanation page. For exact legacy Word layout, export a PDF from Word or Pages first.

## Protecting your library

Open **Settings → iCloud Drive backup** and choose a folder under **iCloud Drive** in the Files picker. Noty creates a `Noty Backup` folder there with versioned editable document packages, then saves changes after edits and checks for updates when the app becomes active. The Files permission is stored as a security-scoped bookmark so it can survive relaunches, and stale bookmarks are refreshed when possible. Noty also requests an iPadOS background-processing retry after cloud backup is configured. The in-app status reports when a copy was saved to the selected folder; iPadOS still decides when background work runs and when the Files provider actually uploads. Check the Files app for upload status before deleting or replacing the app.

If noty is reinstalled or its local data is lost, install and open the app, choose **the same iCloud Drive folder** in Settings, and run the backup check. Noty merges the saved folders, pages, drawings, text boxes, and imported source files into the local library. Until a backup has reached iCloud Drive, local data is still vulnerable to app removal or device loss.

For **OneDrive**, install and sign in to the OneDrive iPad app if your school permits it. In Files, ensure OneDrive appears under **Locations**. Then choose a OneDrive folder in noty’s Settings. Noty keeps the folder grant as a security-scoped bookmark and saves updated, annotated **PDF copies** there after edits, during foreground/background transitions, and during system-scheduled background retry opportunities. iPadOS and the OneDrive Files provider control the eventual network upload. This route deliberately does not need a Microsoft Graph application ID or direct access to Microsoft credentials, which avoids school-tenant app-consent requirements. If your school blocks OneDrive’s Files provider too, that backup destination is unavailable. The OneDrive copy is for reading and sharing; the iCloud Drive backup contains the editable noty library.

## Development

Run the **NotyTests** target in Xcode. Integration tests exercise PDF and DOCX import, page editing, PDF/PNG export, and editable backup recovery using a local folder as a stand-in for a Files provider. The DOCX renderer bundles offline JavaScript dependencies and license files in `Noty/Core/Resources`.

Cloud execution is still best effort: a `BGProcessingTask` gives iPadOS another opportunity to finish cloud work after Noty leaves the foreground, but the system does not guarantee an exact run time and the Files provider controls the final upload. Keep the iCloud Drive folder selected and check the provider’s status in Files when you need to confirm a backup has reached the cloud.
