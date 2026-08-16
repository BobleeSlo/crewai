import Foundation

/// Reads Supabase credentials from the app's Info.plist so secrets stay out of
/// source control. Add two String entries to Info.plist (Xcode → target → Info):
///   - SUPABASE_URL       e.g. https://xxxx.supabase.co
///   - SUPABASE_ANON_KEY  the publishable / anon key from Settings → API
enum SupabaseConfig {
    static var url: URL {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: raw)
        else {
            fatalError("Missing SUPABASE_URL in Info.plist — see MileLog/README.md")
        }
        return url
    }

    static var anonKey: String {
        guard
            let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !key.isEmpty
        else {
            fatalError("Missing SUPABASE_ANON_KEY in Info.plist — see MileLog/README.md")
        }
        return key
    }

    /// Where a password-reset email should send the user back to. Requires
    /// the matching URL scheme to be registered on the target (Xcode →
    /// target → Info → URL Types) AND added to the Supabase project's
    /// Authentication → URL Configuration → Redirect URLs allow-list.
    /// Without both, the reset link lands on the project's Site URL
    /// (`http://localhost:3000` on a default project) and the user can
    /// never actually get back in — see MileLog/README.md.
    static let passwordResetRedirect = URL(string: "milelog://auth/reset")!
}
