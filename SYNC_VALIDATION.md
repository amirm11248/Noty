# Shared Noty sync validation — 3 October 2026

The web editor and iPad synchronizer share Supabase Auth, document/folder tables and authenticated B2 files. B2 credentials stay in Edge Functions. Atomic revision updates, account-scoped browser drafts, iPad baseline checkpoints, immutable asset versions and conflict copies prevent silent document/file overwrites.

## Executed against the deployed backend

An isolated temporary QA account was used; the owner's existing notebook was not edited. Eleven live integration scenarios passed:

1. Create folder and a notebook in the native page format.
2. Deny anonymous signing, cross-account document reads/writes and foreign B2 object keys.
3. Upload/download a real PNG, verify SHA-256, and check B2 browser CORS preflight.
4. Upload/download a 64 MB PDF and verify its full SHA-256.
5. Abort a streamed upload; verify no asset index row was published and incomplete size verification fails.
6. Race revision-predicate updates; confirm the stale write changes zero rows and the existing file snapshot remains available.
7. Trash/restore, star, move and reorder pages, then reread their metadata.
8. Sign out globally, reject the revoked refresh token and sign in again.
9. Permanently delete a document, retain its tombstone and verify its old signed image URL returns 404.
10. Reject wrong-password account deletion.
11. Delete the isolated account with folders and multiple B2 object versions; verify old signed URLs return 404 and its Auth user, folders, documents and asset index rows are gone.

The deletion test exposed an auth-user cascade/tombstone foreign-key bug. `avoid_tombstones_during_account_cascade` fixes it, and the failing case passed on rerun. Both migrations and both updated Edge Functions are deployed.

Local validation: ten web model/import tests, nine account-deletion handler tests and the TypeScript/Vite production build pass. Security advisor findings are existing authenticated GraphQL schema discovery and Auth configuration warnings (password leak protection/MFA); owner row isolation was tested directly. Deno dependency type checking could not fetch registry packages in this environment; deployed Edge Functions executed successfully.

## Still requires device validation

The updated iPad app must be built and installed before it can publish native ink previews or consume browser strokes. This Linux environment cannot operate the user's physical iPad or its signed-in native app. The managed browser-control skill was unavailable, so no visual or real-session browser UI test was claimed.

| Check | Evidence still needed |
| --- | --- |
| User's real iPad notebooks | Sync large existing notes, PDF pages, cropped images, covers and audio; compare native and web rendering. |
| Offline iPad edits | Edit while disconnected, edit the same notebook on web, reconnect; confirm both versions survive as a conflict copy. |
| Simultaneous physical-device edits | Keep both clients open and race metadata, ink and image changes; review checkpoints and immutable asset references. |
| Native Trash/restore/permanent removal | Verify recoverable local packages, asset retention and tombstones on the actual iPad. |
| Physical sign-out/account switching | Verify local data and cloud account boundaries with more than one real account. |

Account deletion was tested exclusively on disposable QA data. Do not delete the user's real account to repeat that test. Native PencilKit strokes are displayed as previews on web; editing existing PencilKit strokes remains an iPad operation. DOCX imports editable text and retains the original, without guaranteeing Word layout. File limit: 250 MB per browser upload.
