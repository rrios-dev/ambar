import AppKit
import Testing

@testable import AppCore

@Suite("Author contact · the About of every app")
struct AuthorContactTests {
    private func links(_ credits: NSAttributedString) -> [String: URL] {
        var found: [String: URL] = [:]
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, range, _ in
            if let url = value as? URL { found[credits.attributedSubstring(from: range).string] = url }
        }
        return found
    }

    @Test("the credits carry the website and the mailbox as links")
    func creditsLinks() {
        let found = links(AuthorContact.credits())
        #expect(found == ["rrios.dev": AuthorContact.website, "roberto@rrios.dev": AuthorContact.mailto])
        #expect(AuthorContact.website.scheme == "https")
        #expect(AuthorContact.mailto.absoluteString == "mailto:" + AuthorContact.email)
    }

    @Test("a tagline comes first and is not a link")
    func tagline() {
        let credits = AuthorContact.credits(tagline: "Clipboard history manager.")
        #expect(credits.string == "Clipboard history manager.\nrrios.dev\nroberto@rrios.dev")
        #expect(links(credits).count == 2)
    }
}
