# Noty shared web editor

This is the source of the existing Noty Sites companion. It uses the same Supabase Auth project, `noty_web_documents`, `noty_web_folders`, `noty_cloud_assets`, and private B2 objects as the native app.

Run `npm ci`, `npm test`, and `npm run build`. Public Supabase project configuration is in `src/cloud.ts`. B2 credentials and the Supabase service role exist only inside Edge Functions.

The page canvas preserves native positioned text boxes, images and crop/rotation settings, PDF source-page indices, page sizes, colors, templates, bookmarks, study cards, audio and unknown JSON fields. Web pen strokes travel as `webStrokes`; the iPad renders them through PencilKit and consumes them into the native drawing once edited. Native drawings travel unchanged with transparent `InkPreviews` PNGs for browser display.

Document saves use an atomic revision predicate. Dirty drafts remain in account-scoped local storage on network failure or remote conflict, with an explicit conflict-copy action. Clean open notebooks and the library poll on visibility/focus and every ten seconds. File transfers use authenticated signed URLs, bounded-memory hashing, retries, upload progress callbacks, server size verification, and an asset index written only after a completed transfer. Files over 250 MB are rejected.

Both clients use immutable content-hashed B2 object keys and store an `assetManifest` on each document revision. A losing save cannot overwrite files referenced by the winning revision. Unreferenced successful uploads are retained until document/account deletion. Trash retains B2 files; permanent deletion records a durable tombstone first and deletes all B2 object versions. Existing Supabase Storage objects remain readable as a compatibility fallback.

PDF pages are rendered with their native annotations on the same canvas. DOCX import extracts editable text and keeps the original file; it does not promise identical Word pagination. The web editor can add and undo web ink; existing native PencilKit ink is displayed as a preview and is edited on iPad.

Deployment identity is managed separately by the existing Sites checkout. See `../SYNC_VALIDATION.md` for the exact tested scope and outstanding physical-device checks.
