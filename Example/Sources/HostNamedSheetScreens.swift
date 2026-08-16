import LightSession
import SwiftUI
import UIKit

/// A sheet the app names itself, over a screen with more in it than the sheet has.
///
/// The shape three separate failures came out of, all from one real screen — a company switcher
/// raised from a list:
///
///  * the app names the sheet with `.lightSessionSubScreen`, and the SDK named it *again* for its
///    shape, composing `List › Trocar empresa › Sheet`: a level the app does not have;
///  * the sheet's own rows arrive from the network after it opens, which is what the late-content
///    watch is for;
///  * and when the sheet closes, the list behind it is **richer than the sheet was**, so the watch
///    reads the dismissal as content arriving and files a picture of the list under the sheet's
///    name — replacing a capture that was correct.
///
/// The third one is why the parent is deliberately the busier of the two. A sheet larger than its
/// parent would close without the node count growing, and the failure would not reproduce.
@available(iOS 16.0, *)
struct HostNamedSheetScreens: View {

    @State private var sheet = false
    @State private var rowsArrived = false

    private var script: [(after: Double, what: String, run: () -> Void)] {
        [
            // Rows before the sheet opens, so it is complete when it settles and the *only* thing the
            // late-content watch ever sees is the dismissal. That is the shape the failure came in:
            // one capture, correct, then one recapture that replaced it with the screen behind.
            (2, "rows ready before the sheet opens", { rowsArrived = true }),
            (3, "sheet up -> expect one sub-screen, named by the app", { sheet = true }),
            // Dismissed by the platform rather than by the app's own state, because that is what a
            // swipe is — and the ordering is the whole failure. Setting `sheet = false` makes SwiftUI
            // run `onDisappear` promptly, the SDK hears about it, and nothing goes wrong. A swipe
            // dismisses first and updates the binding afterwards, so for a moment the sheet is gone
            // while the app still believes it is open. That moment is when the watch recaptures.
            (10, "sheet swiped away -> expect NO resend under the sheet's name", {
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first { $0.isKeyWindow }?
                    .rootViewController?
                    .presentedViewController?
                    .dismiss(animated: true)
            }),
        ]
    }

    var body: some View {
        List {
            ForEach(0..<14, id: \.self) { row in
                HStack(spacing: 12) {
                    Circle().fill(Color.orange.opacity(0.7)).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Disparo \(row + 1)").font(.system(size: 15, weight: .semibold))
                        Text("recorrente · whatsapp").font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(120 + row * 7)").font(.system(size: 13, weight: .medium))
                }
            }
        }
        .lightSessionScreen("List")
        .sheet(isPresented: $sheet) {
            switcher
                .presentationDetents([.large])
                .lightSessionSubScreen("Trocar empresa")
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

    /// Empty when it opens and filled a moment later, the way a switcher that asks a server is.
    private var switcher: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trocar empresa").font(.title3.weight(.semibold))
            TextField("Buscar", text: .constant(""))
                .textFieldStyle(.roundedBorder)

            if rowsArrived {
                ForEach(0..<5, id: \.self) { row in
                    HStack(spacing: 12) {
                        Circle().fill(Color.purple).frame(width: 34, height: 34)
                        Text("Empresa \(row + 1)").font(.system(size: 15))
                        Spacer()
                    }
                }
            } else {
                Text("Carregando…").font(.footnote).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
