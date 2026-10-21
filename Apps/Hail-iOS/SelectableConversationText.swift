import SwiftUI

#if os(iOS)
/// A non-editable, selectable `UITextView`: SwiftUI's `Text` selects only the whole string on iOS.
struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label // Dynamic, so it stays readable in Dark Mode over the clear background.
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) { view.text = text }
}
#else
/// On macOS, SwiftUI's `Text` already selects any part of the string.
struct SelectableText: View {
    let text: String

    var body: some View {
        ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
}
#endif
