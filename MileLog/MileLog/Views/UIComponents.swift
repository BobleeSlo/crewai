import SwiftUI
import UIKit

// MARK: - Keyboard "Done" toolbar

private struct KeyboardDoneToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
                .fontWeight(.semibold)
            }
        }
    }
}

extension View {
    /// Adds a "Done" button above the on-screen keyboard so the user can always
    /// dismiss it — important on forms where the Save / Resolve buttons would
    /// otherwise be hidden underneath.
    func keyboardDoneToolbar() -> some View {
        modifier(KeyboardDoneToolbar())
    }
}

// MARK: - PrettyStepper

/// Modern pill-shaped stepper: large hit targets, monospaced digits in the
/// middle, and clear disabled state at the bounds. Drop-in replacement for the
/// default `Stepper` when you want a more readable presentation.
struct PrettyStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String
    let unit: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundColor(.primary)
                Text("Tap − or + to adjust")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 0) {
                Button { decrement() } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(value <= range.lowerBound)

                Text("\(value) \(unit)")
                    .font(.body.monospacedDigit())
                    .fontWeight(.medium)
                    .frame(minWidth: 56)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.primary)

                Button { increment() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 32)
                        .contentShape(Rectangle())
                }
                .disabled(value >= range.upperBound)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.12))
            )
        }
        .padding(.vertical, 2)
    }

    private func decrement() {
        guard value > range.lowerBound else { return }
        value -= 1
        haptic()
    }

    private func increment() {
        guard value < range.upperBound else { return }
        value += 1
        haptic()
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - SectionHeaderLabel (icon + title for Form section headers)

struct SectionHeaderLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(nil)
    }
}
