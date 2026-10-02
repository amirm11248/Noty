import SwiftUI

struct NotyPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your notes, your space.").font(.largeTitle.weight(.semibold))
                section("On your device", "Notebooks, handwriting, photos, study cards, and lecture recordings are saved locally. Handwriting recognition and Word conversion run on your device. Noty does not send notes to an AI service.")
                section("Photos and microphone", "The photo picker shares only the images you select. Camera and microphone access are requested when you scan a document or record audio. You can change these permissions in iOS Settings.")
                section("Optional sync", "If you choose a folder in Files, Noty writes editable notebook copies there. A separate OneDrive folder can store PDF copies. The provider you select manages uploads and storage. Share folders only with people you trust.")
                section("Optional account", "An account stores your email, account identifier, and workspace setup, including a sync folder name or sharing link you save. Supabase provides account authentication and storage for those settings. Notebook contents stay on your device and in the Files folders you choose.")
                section("Your controls", "You can export notes, restore documents from Trash, disconnect sync folders, sign out, or permanently delete your account in Settings. Deleting an account removes its saved workspace setup. Local notebooks and copies already in your Files folders stay available until you delete them yourself.")
                section("No tracking", "Noty has no advertising or third-party analytics. Your notes are not sold. Account and storage providers may keep operational records needed to run their services.")
            }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }.background { FrostedWorkspaceBackground() }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
    }
    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(text).font(.body).foregroundStyle(.secondary) }
    }
}
