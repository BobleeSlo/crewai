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
                    Text("Your trips are stored in your own Supabase project. " +
                         "Row-Level Security keeps every row private to your account.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("MileLog")
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
            errorMessage = error.localizedDescription
        }
    }
}
