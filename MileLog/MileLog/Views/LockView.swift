import SwiftUI

/// Full-screen lock shown over the app content when the biometric lock is
/// enabled and engaged. Auto-prompts on appear; offers a manual retry button.
struct LockView: View {
    @EnvironmentObject var appLock: AppLock
    @State private var attempted = false

    private var biometry: BiometricAuth.Kind { BiometricAuth.available }

    var body: some View {
        ZStack {
            Theme.brandGradient
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: biometry == .none ? "lock.fill" : biometry.systemImage)
                    .font(.system(size: 64, weight: .light))
                    .foregroundColor(.white)

                VStack(spacing: 8) {
                    Text("MileLog is locked")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("Unlock with \(biometry.label) to continue.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }

                Spacer()

                Button {
                    Task { await appLock.unlock() }
                } label: {
                    Label("Unlock", systemImage: biometry.systemImage)
                        .font(.headline)
                        .foregroundColor(Theme.brandStart)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .task {
            // Auto-prompt once when the lock screen first appears.
            guard !attempted else { return }
            attempted = true
            await appLock.unlock()
        }
    }
}
