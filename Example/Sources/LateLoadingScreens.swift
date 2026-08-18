import LightSession
import SwiftUI

/// A screen that shows placeholder cards while it waits, then replaces them with real rows.
///
/// The shape a stored capture froze in, in production. `ScreenSettle` asks whether the content has
/// stopped changing, not whether it has finished *loading* — and a placeholder holds perfectly still,
/// so it settles and gets captured, exactly as designed. `LateContentWatch` is what should then
/// notice the real content and resend.
///
/// What it exists to catch: the additive rule (`SkeletonBuilder.retainsMostOf`) refusing that
/// resend. Placeholder cards and loaded rows share almost nothing by position or kind, so the rule
/// reads the upgrade as a change of screen and the capture stays frozen on the placeholder for good.
///
/// Invisible against a mock, which is why it took production to find: the wait has to outlast the
/// settle for the placeholder to be what gets captured in the first place. `-demoLoadMs` sets it.
@available(iOS 16.0, *)
struct LateLoadingScreens: View {

    @State private var loaded = false

    /// Milliseconds before the real rows arrive. Long enough by default that the placeholder is
    /// unambiguously what settled.
    private var wait: Double {
        let ms = UserDefaults.standard.double(forKey: "demoLoadMs")
        return ms > 0 ? ms : 2500
    }

    var body: some View {
        Group {
            if loaded { rows } else { placeholders }
        }
        .lightSessionScreen("Dispatches")
        .onAppear {
            guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
            print("[demo] placeholders up; real rows in \(Int(wait))ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait / 1000) {
                print("[demo] rows arrived -> expect a resend, not a refusal")
                loaded = true
            }
        }
    }

    /// Five grey blocks. Deliberately unlike the loaded state: that difference is the bug.
    private var placeholders: some View {
        VStack(spacing: 12) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.gray.opacity(0.28))
                    .frame(height: 96)
            }
            Spacer()
        }
        .padding(16)
    }

    /// The real thing: many more rectangles, at different places, of different kinds.
    private var rows: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(0..<12, id: \.self) { row in
                    HStack(spacing: 12) {
                        Circle().fill(Color.orange.opacity(0.75)).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Disparo \(row + 1)").font(.system(size: 15, weight: .semibold))
                            Text("recorrente · whatsapp · \(120 + row * 9) envios")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(row * 3)%").font(.system(size: 13, weight: .medium))
                    }
                    .padding(12)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
        }
    }
}
