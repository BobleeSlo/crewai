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
            // Deliberately no Cancel: the recovery session is short-lived,
            // and dismissing without setting a password would leave the
            // user signed in via a link they can't re-use, which is more
            // confusing than finishing the one step they came here for.
        }
        .interactiveDismissDisabled()
    }

    private func submit() async {
        errorMessage = nil
        do {
            try await supabase.updatePassword(password)
            dismiss()
        } catch {
            errorMessage = "Couldn't set the new password. The reset link may have expired — request a fresh one from the sign-in screen."
        }
    }
}
