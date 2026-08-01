import LightSession
import SwiftUI

/// Screen A with a sheet over it, to see what the SDK thinks is on screen after the sheet closes.
///
/// A SwiftUI sheet is a page sheet: it does not remove the screen underneath from the hierarchy, so
/// closing it may emit no appearance callback at all for the screen coming back. If the SDK never
/// learns, the screenshot it takes five seconds later is of screen A and is filed under the sheet.
@available(iOS 16.0, *)
struct SheetReturnScreens: View {

    @State private var sheetUp = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text("Screen A").font(.largeTitle)
                Text("The sheet below is a different screen; coming back here is the question.")
                    .font(.footnote).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            .navigationTitle("Screen A")
        }
        .sheet(isPresented: $sheetUp) {
            NavigationStack {
                Text("Inside the sheet").padding()
                    .navigationTitle("The Sheet")
            }
        }
        .onAppear(perform: walkIfAsked)
    }

    private func walkIfAsked() {
        guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("[demo] open the sheet")
            sheetUp = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            print("[demo] close the sheet — back on Screen A")
            sheetUp = false
        }
        // Longer than the quiet period, so whatever screenshot is going to happen has happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            print("[demo] quiet period is over")
        }
    }
}
