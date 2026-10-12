import SwiftUI

struct NotyPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your notes, your space.").font(.largeTitle.weight(.semibold))
                section("On your device", "Notebooks, handwriting, photos, and study cards are saved locally. Handwriting recognition and Word conversion run on your device. Noty does not send notes to an AI service.")
                section("Photos and camera", "The photo picker shares only the images you select. Camera access is requested when you scan a document. You can change these permissions in iOS Settings.")
                section("Local storage only", "This version has no accounts, cloud sync, or backend connection. The library, imported originals, and exports are excluded from system backups. Word conversion blocks remote content, and copied page objects stay in the device's clipboard.")
                section("Exports", "PDFs and images are saved in On My iPhone or On My iPad → noty → Noty Exports. Noty does not upload them. If you move files using another app, that app controls where they go.")
                section("Your controls", "You can export notes, restore documents from Trash, and permanently delete local notes. Keep your own local copies before deleting Noty or erasing your device; there is no cloud recovery.")
                section("No tracking", "Noty has no advertising, third-party analytics, or remote data collection. Your notes are not sold.")
            }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }.background { FrostedWorkspaceBackground() }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
    }
    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(text).font(.body).foregroundStyle(.secondary) }
    }
}
