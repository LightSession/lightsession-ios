import LightSession
import SwiftUI

/// One screen, two different sheets, neither named by the app.
///
/// The collision this exists to measure: with nothing declared, `modalLayerName` falls back to a
/// word for the *shape*, and both sheets are `.pageSheet` — so both compose to `Two › Sheet` with the
/// same composite id, and whichever is captured last overwrites the other. One node standing in for
/// two screens, and nothing anywhere says so.
///
/// Deliberately un-annotated. The question is what the SDK does for an app that opens two sheets
/// without knowing `.lightSessionSubScreen` exists — which is every app until someone reads the
/// documentation.
///
/// The two sheets are structurally different on purpose: different detents, different content shape.
/// If nothing about them differs in a way the SDK can read, the answer is that they cannot be told
/// apart and the fix has to be something other than a better name.
@available(iOS 16.0, *)
struct TwoSheetsScreens: View {

    private enum Which: String, Identifiable {
        case filters, share
        var id: String { rawValue }
    }

    @State private var showing: Which?

    private var script: [(after: Double, what: String, run: () -> Void)] {
        [
            (3, "sheet A (filters) up", { showing = .filters }),
            (8, "sheet A down", { showing = nil }),
            (11, "sheet B (share) up -> expect a DIFFERENT node from A", { showing = .share }),
            (16, "sheet B down", { showing = nil }),
        ]
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Two").font(.title2)
            ForEach(0..<6, id: \.self) { row in
                Text("linha \(row + 1)").font(.system(size: 14))
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .lightSessionScreen("Two")
        .sheet(item: $showing) { which in
            switch which {
            case .filters: filters
            case .share: share
            }
        }
        .onAppear {
            guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
            for step in script {
                DispatchQueue.main.asyncAfter(deadline: .now() + step.after) {
                    print("[demo] \(step.what)")
                    step.run()
                }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filtros").font(.title3.weight(.semibold))
            ForEach(0..<4, id: \.self) { row in
                HStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.blue).frame(width: 26, height: 26)
                    Text("opção \(row + 1)")
                    Spacer()
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .presentationDetents([.medium])
    }

    private var share: some View {
        VStack(spacing: 18) {
            Text("Compartilhar").font(.title3.weight(.semibold))
            HStack(spacing: 20) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.green).frame(width: 54, height: 54)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.large])
    }
}
