import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Lets the user dismiss the keyboard by dragging the scroll content down (scroll) or tapping
    /// a "Done" button that appears above the keyboard.
    func keyboardDismissable() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold)
                }
            }
    }
}
