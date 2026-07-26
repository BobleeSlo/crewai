import SwiftUI

struct AuthView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password (min 6 characters)", text: $password)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
                if let infoMessage {
                    Text(infoMessage)
                        .foregroundColor(.secondary)
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
                                Text(isSignUp ? "Create account" : "Sign in").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(supabase.isWorking || !canSubmit)

                    Button(isSignUp ? "I already have an account" : "Create a new account") {
                        isSignUp.toggle()
                        errorMessage = nil
                        infoMessage = nil
                    }
                    .font(.footnote)
                }

                Section {
                    // "Supabase"/"Row-Level Security" is backend
                    // vocabulary, shown before a first-time, non-technical
                    // user has even created an account (round-2 UX review
                    // finding).
                    Text("Your trips are private and only visible to you.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("MileLog")
            .keyboardDoneToolbar()
        }
    }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6
    }

    private func submit() async {
        errorMessage = nil
        infoMessage = nil
        do {
            if isSignUp {
                try await supabase.signUp(email: email, password: password)
                if !supabase.isAuthenticated {
                    infoMessage = "Account created. Check your email to confirm, then sign in."
                    isSignUp = false
                }
            } else {
                try await supabase.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = Self.friendlyAuthError(error)
        }
    }

    /// The app's front door showed raw SDK/network error text
    /// (`error.localizedDescription`) with zero MileLog-authored
    /// explanation — wrong-password/network/already-registered are
    /// common-path here, not edge cases, for a non-technical user's very
    /// first interaction with the app (round-2 UX review finding).
    private static func friendlyAuthError(_ error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("invalid login credentials") || raw.contains("invalid_grant") {
            return "That email or password isn't right. Check them and try again."
        }
        if raw.contains("already registered") || raw.contains("already exists") {
            return "An account with that email already exists — try signing in instead."
        }
        // Narrower than a bare "password" match: Supabase's own password
        // policy (minimum length, breach checks, complexity) is server-
        // configurable independent of this app's local 6-character check,
        // so "any error mentioning password" previously produced this same
        // confidently-wrong explanation for something that might not
        // actually be a length issue at all (round-3 UX review finding).
        if raw.contains("password")
            && (raw.contains("short") || raw.contains("least") || raw.contains("weak") || raw.contains("characters")) {
            return "Password needs to be at least 6 characters."
        }
        if raw.contains("network") || raw.contains("offline") || raw.contains("internet connection") {
            return "Couldn't connect. Check your internet connection and try again."
        }
        return "Something went wrong. Please try again in a moment."
    }
}
