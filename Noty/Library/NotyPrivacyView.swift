import SwiftUI

struct NotyPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your notes, your space.").font(.largeTitle.weight(.semibold))
                section("On your device", "Notebooks, handwriting, photos, study cards, and lecture recordings are saved locally first. Writing and editing do not depend on an internet connection. Handwriting recognition and Word conversion run on your device.")
                section("Noty Cloud", "When you sign in, Noty synchronizes your editable library with your account so the same notebooks can be used by iOS and the web app. Supabase stores account and structured library data. Private Backblaze B2 storage holds binary notebook files such as PDFs, PencilKit drawings, photos, audio, and imported originals. Backblaze credentials remain on the server and are not embedded in the app.")
                section("Photos and microphone", "The photo picker shares only the images you select. Camera and microphone access are requested when you scan a document or record audio. You can change these permissions in iOS Settings.")
                section("Optional backups", "You can still choose a writable Files/iCloud folder for an additional editable backup and a OneDrive Files-provider folder for rendered PDF copies. Those providers manage their own uploads and storage.")
                section("Your controls", "You can export notes, restore documents from Trash, use optional backup folders, sign out, or permanently delete your account in Settings. Signing out leaves the local working copy on this device.")
                section("No tracking", "Noty has no advertising or third-party analytics. Your notes are not sold. Account and storage providers may keep operational records needed to run their services.")
            }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }.background { FrostedWorkspaceBackground() }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.body).foregroundStyle(.secondary)
        }
    }
}
