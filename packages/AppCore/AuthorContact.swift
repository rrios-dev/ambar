import AppKit
import SwiftUI

/// Where the author of these apps is found: the website and its mailbox, shown in every
/// app's About (owner request, 2026-11-18). One place, so the apps never disagree.
public enum AuthorContact {
    public static let websiteLabel = "rrios.dev"
    public static let website = URL(string: "https://rrios.dev")!
    public static let email = "roberto@rrios.dev"
    public static let mailto = URL(string: "mailto:roberto@rrios.dev")!

    /// The credits of the system's About panel (`NSApplication.AboutPanelOptionKey.credits`):
    /// an optional tagline, then the website and the mailbox as links, centred.
    public static func credits(tagline: String? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString()
        if let tagline, !tagline.isEmpty {
            credits.append(NSAttributedString(string: tagline + "\n", attributes: base))
        }
        for (label, url, last) in [(websiteLabel, website, false), (email, mailto, true)] {
            var attributes = base
            attributes[.link] = url
            credits.append(NSAttributedString(string: label, attributes: attributes))
            if !last { credits.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        return credits
    }
}

/// The same two links for a SwiftUI About: website and mailbox, side by side.
public struct AuthorContactLinks: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 12) {
            Link(AuthorContact.websiteLabel, destination: AuthorContact.website)
            Link(AuthorContact.email, destination: AuthorContact.mailto)
        }
        .font(.callout)
    }
}
