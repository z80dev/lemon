#if os(iOS)
import SwiftUI
import UIKit

/// A multiline editor, not a submit-oriented text field: Return and Shift+Return always insert a newline.
struct IOSComposerInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let maximumLines: Int

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.text = text
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .callout, compatibleWith: view.traitCollection)
        view.textColor = UIColor(LB.ink)
        view.tintColor = UIColor(LB.accent)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.returnKeyType = .default
        view.accessibilityLabel = "Unsent message draft"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateText(text, in: view)
        if focused != view.isFirstResponder {
            if focused { view.becomeFirstResponder() }
            else { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let font = view.font else { return nil }
        let content = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let limit = min(font.lineHeight * CGFloat(maximumLines), proposal.height ?? .greatestFiniteMagnitude)
        return CGSize(width: width, height: max(font.lineHeight, min(content.height, limit)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSComposerInput
        private var reportedText: String
        init(_ parent: IOSComposerInput) { self.parent = parent; reportedText = parent.text }
        func updateText(_ text: String, in view: UITextView) {
            // A layout update can arrive between UIKit inserting a character and its delegate callback.
            // Only a new model value is authoritative; do not replace an in-progress native edit.
            guard text != reportedText, view.markedTextRange == nil else { return }
            reportedText = text
            if view.text != text { view.text = text; view.invalidateIntrinsicContentSize() }
        }
        func textViewDidChange(_ view: UITextView) {
            let text = view.text ?? ""
            reportedText = text
            parent.text = text
            view.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ view: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ view: UITextView) { parent.focused = false }
    }
}
#endif
