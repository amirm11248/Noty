# Noty release readiness

Updated 2026-10-02. This is a native iOS/iPadOS app; the localhost browser preview displays the actual iPad app.

## Implemented for this release

- Frosted notebook library, customizable folders with photos, a simplified sidebar, adaptive dark appearance and responsive shelf/list views.
- Notebook creation chooses a cover and paper. The cover is page 1, remains first, and appears in presentation and exports. Existing notebooks migrate on opening without changing writing-page IDs or assets.
- PencilKit pens/highlighter, direct eraser/lasso/pan, ruler and shapes, zoom, four toolbar positions, text boxes, photo objects/cropping, named bookmarks and notebook search.
- Shared undo/redo for ink, text and photos. Photo deletion retains its asset for undo until the editor closes, then unused assets are removed.
- Freehand/rectangular lasso selects ink, text boxes and photos together. It has content filters, live group movement/resizing and cut/copy/paste/duplicate/delete. Group edits share a single undo step; copied photos retain their original bytes, crop and rotation, and pasted groups fit the destination paper.
- Study cards, review sessions, a focus timer and lecture audio with playback speed, seeking, export and a link to its starting page.
- PDF/DOCX import, PDF/PNG export, local persistence, Trash recovery, editable Files-folder backup and a OneDrive PDF mirror.
- In-app privacy information, privacy manifest, microphone purpose text and an authenticated account-deletion function deployed to the existing Noty Supabase project.

## Verification

- Debug build and launch and an unsigned Release simulator build succeed on the iPad iOS 26.5 runtime.
- The unsigned arm64 iOS Release archive also builds successfully. It includes the privacy manifest, microphone/camera purpose strings and an adaptive launch-screen configuration. The redesigned minimal frosted notebook icon is a 1024 × 1024 opaque RGB asset, checked at small sizes and on the installed app's Home Screen in the browser preview. The archive was rebuilt with the new icon. Signing and App Store validation remain owner steps.
- All 29 native tests pass. They exercise import fidelity, ink/text/photo persistence, cover migration and protection, original and rotated PDF dimensions, exported content, study-card duplication, non-destructive crop, rotated photo orientation and original-file preservation, text/photo undo, native text-input focus, Unicode and underline formatting, legacy decoding, Trash, Files bookmarks, unchanged backup reuse and folder/cover/photo/audio recovery. Lasso regressions cover mixed selections and content filters, rotated-photo hit testing, erased ink gaps, stroke/pressure preservation, proportional text spacing, atomic undo steps, cross-document paste and staged-photo rollback after a failed paste.
- The browser mirror renders real native frames. Light/dark library appearance, folder separation, folder customization, cover page 1, paper display, top/bottom/left/right toolbar docking and button-based page zoom have been checked there. Docking persists through relaunch. Notebook creation presents separate Cover and Paper sections; template, size and orientation controls have also been checked in the browser.
- In the browser's landscape editor, rectangular lasso settings, grouped text selection, movement, one-step movement undo, proportional resizing, the selection menu and duplication have been checked. Native tests exercise the mixed ink/text/photo geometry and original-photo clipboard fidelity; physical Pencil and multitouch checks remain below.
- The account-deletion handler type-checks and passes eight security/behavior tests. Authentication is enforced at the gateway and again inside the handler; re-authentication must identify the same account before sessions are revoked and that account is deleted. Live unauthenticated calls are rejected. No real user account was deleted for testing.
- CI uses Xcode 26.3, builds the app, runs the integration suite on an available iPad runtime and preserves its result bundle. The updated workflow has not been dispatched to GitHub from this workspace.
- `FEATURE_STATUS.md` lists remaining advanced Goodnotes differences. AI features are outside this release.

Latest full native test result: `test_sim_2026-10-02T06-14-30-512Z_pid29017_d57ad209.xcresult` in the local XcodeBuildMCP workspace. The final copied-ink regression also passes in `test_sim_2026-10-02T06-27-37-972Z_pid29017_52b4d155.xcresult`; duplicating ink preserves independent strokes through encoding. The current Debug build/launch log is `build_run_sim_2026-10-02T06-28-53-490Z_pid29017_b79d95d7.log`. The current arm64 Release archive includes the mixed-content lasso, its clipboard type declaration and the redesigned icon; its build log is `noty-qa/ios-archive-build.log`. The earlier unsigned Release simulator build log is `build_sim_2026-10-01T19-26-38-065Z_pid29017_32395157.log`. The final text-input implementation is covered by the native runtime test. Visual layout is also checked in the browser mirror. Keyboard input through the preview bridge is unreliable; the native text-input runtime test verifies focus, Unicode insertion and underline formatting directly.

The review archive and build log are saved in `/Users/malik/.codex/visualizations/2026/10/01/01a0f90a-220f-7b22-aac2-35f61ddf994c/Noty-unsigned.xcarchive.zip` and `noty-qa/ios-archive-build.log`. The native landscape lasso screenshot is `noty-qa/mixed-lasso.jpg` in the same artifact directory. An unsigned archive is not installable or ready to upload without signing. Rebuild the submission archive with the owner's development team and an App Store-supported public Xcode release.

## Checks that require a physical device or owner access

These are release gates, not claims of completed verification:

1. Install a signed Release build with the owner's Apple development team. Test Apple Pencil pressure/latency, palm rejection, finger pan, native lasso, pinch zoom and toolbar docking in portrait, landscape and Split View.
2. Record and play real microphone audio, test headphones/Bluetooth and interruptions, and verify short recordings survive leaving the notebook. Recording stops on leaving the notebook or entering the background.
3. Select real iCloud Drive/OneDrive locations. Verify provider uploads, relaunch access, recovery on a second device and folder/cover/photo/audio edits through the editable backup. Local-folder tests cannot certify a File Provider's network upload.
4. Exercise signup, email confirmation, sign-in, sign-out and permanent deletion with a disposable test account. Verify mail delivery and account-deletion behavior on the deployed project; never use a real study account as a test fixture.
5. Complete App Store Connect metadata, owner support contact, a public privacy-policy URL, screenshots, privacy answers and the signing/archive/upload steps. The app is not published by this task.

## Known product boundaries

- The app lasso selects added ink, text boxes and photo objects. Printed content inside a source PDF remains part of the PDF background. The native PencilKit picker also retains its own ink-only lasso.
- Lecture clips link to a starting page; stroke-by-stroke audio-synchronized replay is not implemented.
- Exact legacy `.doc` layout, imported reusable paper templates, automatic shape recognition, scribble erase, a dedicated zoom-writing window, notebook passwords, semantic PDF highlight annotations, reusable sticker libraries and live collaboration remain outside the implemented feature set.
- Cloud merging resolves document revisions by timestamps. It does not merge concurrent strokes inside the same notebook.
