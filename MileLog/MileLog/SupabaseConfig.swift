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
}
