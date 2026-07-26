import SwiftUI

/// Final step of the password-reset flow: the user has tapped the link in
/// their email, `SupabaseService.handleRecoveryLink` has exchanged it for a
/// short-lived recovery session, and this screen sets the new password.
///
/// Round 5 added a "Forgot password?" button that sent the email but had
/// nowhere for the link to land — no URL scheme, no handler, no screen — so
/// the affordance promised recovery it couldn't deliver (round-6 UX review
/// finding). This is the missing half.
struct SetNewPasswordView: View {
    @EnvironmentObject var supabase: SupabaseService
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        password.count >= 6 && password == confirmation
    }

    /// Only shown once the user has typed enough to have made a mistake —
    /// scolding someone mid-keystroke about a password they're still
    /// typing is noise, not help.
    private var mismatchWarning: String? {
        guard !confirmation.isEmpty, password != confirmation else { return nil }
        return "The two passwords don't match."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password (min 6 characters)", text: $password)
                    SecureField("Confirm new password", text: $confirmation)
                } footer: {
                    if let mismatchWarning {
                        Text(mismatchWarning).foregroundColor(.red)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if supabase.isWorking {
                                ProgressView()
                            } else {
                                Text("Set new password").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(supabase.isWorking || !canSubmit)
                }
            }
            .navigationTitle("New password")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // There MUST be an exit. `handleRecoveryLink` has
                    // already established a session and flipped
                    // `isAuthenticated`, so there's no sign-in screen left
                    // behind this sheet — and with no Cancel and
                    // `.interactiveDismissDisabled()`, a failed update (an
                    // expired or already-used link, which no amount of
                    // retrying fixes) trapped the user in an undismissable
                    // modal whose own error copy told them to go somewhere
                    // they couldn't reach. Only a force-quit escaped it
                    // (round-7 UX review finding). Signing out on the way
                    // out returns them to the screen the copy names.
                    Button("Cancel") {
                        Task {
                            await supabase.signOut()
                            dismiss()
                        }
                    }
                    .disabled(supabase.isWorking)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func submit() async {
        errorMessage = nil
        do {
            try await supabase.updatePassword(password)
            dismiss()
        } catch {
            // Doesn't blame link expiry outright: this same path catches a
            // server-side password-policy rejection and a plain network
            // failure, neither of which is helped by requesting a new link
            // (round-7 UX review finding).
            errorMessage = "Couldn't set the new password. Check your connection and try again — or tap Cancel and request a fresh reset link from the sign-in screen."
        }
    }
}
