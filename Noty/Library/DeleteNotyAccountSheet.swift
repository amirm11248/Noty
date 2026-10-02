import SwiftUI

struct DeleteNotyAccountSheet: View {
    let account: NotyAccountService
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Delete your Noty account?").font(.title3.weight(.semibold))
                    Text("This permanently removes your account and its saved workspace settings. Your notebooks on this device and in your Files folders remain available.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Confirm your identity") {
                    SecureField("Current password", text: $password).textContentType(.password)
                    TextField("Type DELETE", text: $confirmation).autocorrectionDisabled().textInputAutocapitalization(.characters)
                }
                Section {
                    Button("Permanently delete account", role: .destructive) {
                        Task {
                            do { try await account.deleteAccount(password: password); password = ""; dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(confirmation != "DELETE" || password.isEmpty || account.isWorking)
                    if account.isWorking { ProgressView("Deleting account…") }
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }.navigationTitle("Delete account").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { password = ""; dismiss() }.disabled(account.isWorking) } }
                .interactiveDismissDisabled(account.isWorking)
        }
    }
}
