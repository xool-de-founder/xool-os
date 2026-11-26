import SwiftUI

/// A message's text. Where it holds a link to a Brain entry
/// (`[Title](xool-brain://id)`, which agents cite and `@` writes), the
/// Markdown is read and the link opens that entry in the Brain; anything
/// else is shown exactly as it was written.
struct BrainText: View {
    let text: String

    var body: some View {
        if text.contains("xool-brain://"),
           let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(Self.styled(attributed))
                .environment(\.openURL, OpenURLAction { url in
                    if let id = BrainStore.id(from: url) { BrainStore.shared.show(id); return .handled }
                    return .systemAction
                })
        } else {
            Text(text)
        }
    }

    /// Links to the Brain stand out of the text: underlined, in the focus colour.
    static func styled(_ text: AttributedString) -> AttributedString {
        var out = text
        for run in out.runs where run.link != nil {
            out[run.range].foregroundColor = Theme.focus
            out[run.range].underlineStyle = .single
        }
        return out
    }
}
