import SwiftUI

/// The shape a real form sheet has, to see how much of it the wireframe finds.
///
/// A stored capture of one of these came back as two rectangles: the navigation bar's two labels, and
/// nothing else — no fields, no button — while the *masked screenshot* of the same screen showed all
/// five, correctly covered. The mask and the wireframe read the same snapshot, so whatever is lost is
/// lost after the reading.
@available(iOS 16.0, *)
struct RichSheetScreens: View {

    @State private var sheetUp = false

    var body: some View {
        // A plain root, not a NavigationStack — the sheet in the real app is raised from a screen the
        // route names, with no navigation controller of its own anywhere above it.
        VStack { Text("Behind").font(.largeTitle) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $sheetUp) {
            NavigationStack {
                // The same form inside a ScrollView, which is the one structural difference between
                // this and the real app's sheet that came back as two rectangles.
                ScrollView {
                VStack(spacing: 16) {
                    Text("Enter the code we sent you.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(["E-mail", "Código", "Senha", "Confirmar senha"], id: \.self) { field in
                        // Built the way the real app builds them: no `textFieldStyle`, a colour behind,
                        // a clip shape and an overlay border. Three modifiers that each add a layer.
                        TextField(field, text: .constant(""))
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .background(Color(white: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(white: 0.85), lineWidth: 1)
                            )
                    }

                    Button {
                    } label: {
                        Text("Ativar")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }
                .padding()
                }
                // The one thing the real app has that this did not: an opaque background covering the
                // whole sheet. There is a rule that discards everything already collected when an
                // opaque cover spans the capture — written for a navigation transition, where the
                // screen being left really is behind the screen being entered.
                .background(Color(white: 0.97))
                .navigationTitle("Rich Sheet")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") {}
                    }
                }
            }
        }
        .onAppear {
            guard UserDefaults.standard.bool(forKey: "demoNav") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("[demo] sheet with four fields and a button")
                sheetUp = true
            }
        }
    }
}
