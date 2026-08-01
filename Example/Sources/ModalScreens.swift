import LightSession
import SwiftUI
import UIKit

/// The ways a screen can be covered, which are not one behaviour but three.
///
/// The difference is what the platform tells the SDK when the cover goes away, and it decides whether
/// the screen underneath is ever picked up again:
///
///  * a **full-screen modal** removes the presenter from the hierarchy, so it gets `viewDidAppear`
///    when the modal closes and the SDK learns for free;
///  * a **page sheet** does not, so closing it emits nothing — the case that had the SDK stuck on the
///    sheet, taking the screen underneath's screenshot and filing it under the sheet;
///  * an **alert or a popover** is not a screen at all and must be dropped.
///
/// Having all three next to each other is the point: the fix for one must not change the others.

/// A UIKit modal presented full screen.
final class FullScreenModalHost: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Presenter"
        view.backgroundColor = .systemBackground
        addCentredLabel("A full-screen modal covers this in two seconds and leaves four seconds later.")

        guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let modal = PresentedFullScreenViewController()
            modal.modalPresentationStyle = .fullScreen
            print("[demo] presenting full screen")
            self.present(modal, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                print("[demo] dismissing — the presenter should be picked up again")
                modal.dismiss(animated: true)
            }
        }
    }
}

final class PresentedFullScreenViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Presented full screen"
        view.backgroundColor = .systemIndigo.withAlphaComponent(0.12)
        addCentredLabel("Full screen, so the presenter really did disappear.")
    }
}

/// The SwiftUI covers, side by side.
///
/// `fullScreenCover` and `sheet` look alike in the source and behave differently underneath, which is
/// exactly the kind of difference a sample exists to make visible.
@available(iOS 16.0, *)
struct CoversScreens: View {

    @State private var sheetUp = false
    @State private var coverUp = false
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Covers").font(.largeTitle)
                Text("A sheet, a full-screen cover and a confirmation dialog, in that order.")
                    .font(.footnote).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            .navigationTitle("Covers")
        }
        .sheet(isPresented: $sheetUp) {
            NavigationStack {
                Text("A page sheet leaves the screen underneath in place.")
                    .padding().navigationTitle("The Sheet")
            }
        }
        .fullScreenCover(isPresented: $coverUp) {
            NavigationStack {
                Text("A full-screen cover removes it.")
                    .padding().navigationTitle("The Cover")
            }
        }
        .confirmationDialog("Sure?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        }
        .onAppear(perform: walkIfAsked)
    }

    private func walkIfAsked() {
        guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
        let script: [(Double, String, () -> Void)] = [
            (2, "sheet up", { sheetUp = true }),
            (5, "sheet down", { sheetUp = false }),
            (8, "cover up", { coverUp = true }),
            (11, "cover down", { coverUp = false }),
            (14, "confirmation dialog up", { confirming = true }),
            (17, "confirmation dialog down", { confirming = false }),
        ]
        for (after, what, run) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                print("[demo] \(what)")
                run()
            }
        }
    }
}
