# Noty privacy notice

**Source reviewed:** 2026-10-11

**Maintainer:** [Malik Abdullah Amir](https://github.com/amirm11248)

This technical notice describes the source in this repository and complements
the native app's Privacy screen. The project's current personal hobby purpose
is recorded in [PROJECT_STATUS.md](PROJECT_STATUS.md).

A deployed app or cloud service needs a privacy policy matching its actual
operator and configuration, including controller/contact details, purposes and
legal bases, recipients and transfers, retention, and applicable user rights.
Those deployment details are not established by this repository notice.
See the disclosure requirements in
[GDPR Article 13](https://eur-lex.europa.eu/eli/reg/2016/679/oj/eng).

## Local notes and device permissions

The native app stores notebooks, handwriting, imported documents, photos,
study cards, and lecture recordings locally. Handwriting recognition and native
Word conversion run on the device. Imported originals and exports can remain
in the app's local files.

Photo selection shares the images a person chooses. Camera and microphone
permission are requested for document scanning and lecture recording. These
permissions can be changed in iOS Settings. Recording stops when leaving the
notebook or entering the background.

## Accounts and Noty Cloud

Creating or using an account sends authentication requests to Supabase Auth.
The account uses an email address and user ID. The native app stores its session
in the device Keychain; the web client uses the Supabase browser session store.

When signed in, Noty synchronizes account-linked notebook and folder data,
workspace metadata, document revisions, and an asset index through Supabase.
Private Backblaze B2 objects hold notebook files such as PDFs, drawings, photos,
recordings, and imported originals. Existing Supabase Storage objects can still
be read as a compatibility fallback. Authenticated server functions issue
temporary signed URLs for file transfers.

Cloud providers process these data to provide authentication, storage, and sync.
Their operational records, storage regions, backup retention, and contractual
terms depend on the deployment. The source code does not establish a complete
retention schedule for those services.

## Browser storage and optional backup folders

The web client stores interface preferences and account-scoped unsaved notebook
drafts in browser local storage. Failed saves can leave recoverable local
drafts. Browser/site-data controls can remove that local data.

Choosing a Files/iCloud folder creates an additional editable backup. Choosing
a OneDrive Files-provider folder creates rendered PDF copies. Those providers
control their uploads and storage. Saved workspace links can be stored in the
Noty account; treat a folder shared with anyone holding its link as sensitive.

## Retention and deletion

Moving a notebook to Trash retains its cloud files for recovery. Permanent
document deletion records a tombstone and requests deletion of its cloud
objects. The account-deletion flow verifies the account, requests cloud-file
cleanup, revokes sessions, and deletes that account. Actual completion can fail
and require retrying; provider logs and backups have separate retention.

Signing out leaves the native local working copy and selected backup folders
on the device. Account deletion also leaves native local notebooks and copies
in independently selected iCloud/OneDrive folders. Remove those copies through
the app or provider if desired. Export needed notes before permanent deletion.

## Tracking and reports

The source contains no advertising or third-party analytics integration.
Account, hosting, and storage providers may retain operational records needed
to run their services. Personal notes and recordings should never be attached
to public repository issues; follow [SECURITY.md](SECURITY.md) for private
security reports.
