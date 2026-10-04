import SwiftUI

/// One of Cursor's own cards on its session's row (CursorAccessibility): what Cursor is asking, and the buttons it
/// shows, in its words and order. The primary button (Run, Switch, Build) is filled, as Cursor fills it.
struct CursorCardView: View {
    let card: CursorCard
    let hideDetails: Bool
    let press: (String) -> Void

    static let primary: Set<String> = ["run", "switch", "build"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).imageScale(.small)
                Text(title).fontWeight(.semibold)
            }
            .font(.caption)
            // A Run card keeps its command whatever is hidden, as the request card keeps its summary: Run and Always
            // Run are not offered to someone who cannot read what they would run.
            if !hideDetails || card.kind == .run, let heading = card.heading, heading != title {
                Text(verbatim: heading).font(.caption2).foregroundStyle(Caption.style).lineLimit(2).truncationMode(.tail)
            }
            HStack(spacing: 6) {
                ForEach(card.options, id: \.self) { option in
                    Button(option.label) { press(option.label) }
                        .buttonStyle(PromptButtonStyle(filled: Self.primary.contains(option.label.lowercased())))
                        .accessibilityHint(L("Presses this button on Cursor's card"))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Themed.wash(Palette.calm, 0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch card.kind {
        case .run: L("Cursor is waiting to run a command")
        case .modeSwitch: hideDetails ? L("Cursor asks to switch mode") : card.heading ?? L("Cursor asks to switch mode")
        case .plan: L("Cursor's plan is ready to build")
        }
    }

    private var symbol: String {
        switch card.kind {
        case .run: "terminal"
        case .modeSwitch: "arrow.left.arrow.right"
        case .plan: "list.bullet.clipboard"
        }
    }
}
