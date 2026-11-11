import AppKit

/// A question whose yes must be a deliberate act (shared-control S8 fix round, X1): the usage statistics'
/// consent (Quill J-11) under the EU's rule that consent is "an unambiguous indication" (GDPR art. 4(11)).
///
/// A plain `NSAlert` makes its first button the default: it appears over whatever the user is typing,
/// takes the keyboard, and a Return meant for a document says yes. Here no button answers Return, and yes
/// never takes the keyboard, so a Space cannot press it either; Escape answers no, a refusal costs nothing.
/// Yes is a click or VoiceOver's press.
public enum ConsentAlert {
    /// The alert, built and laid out, not shown: the first button is yes, the second no.
    @MainActor
    public static func make(title: String, message: String, yes: String, no: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let accept = alert.addButton(withTitle: yes)
        let decline = alert.addButton(withTitle: no)
        // Docs: https://developer.apple.com/documentation/appkit/nsalert/addbutton(withtitle:) — the first
        // button gets Return, a "Cancel" or "Don't Save" one gets Escape; both are set here instead.
        accept.keyEquivalent = ""
        decline.keyEquivalent = "\u{1b}"
        // NSAlert puts the keyboard on its first button whatever `initialFirstResponder` says (measured: the
        // test saw a button there after setting nil), so yes never takes the keyboard at all: Space can only
        // ever press no. Yes stays a click or VoiceOver's press; the Settings switch is the keyboard's way.
        accept.refusesFirstResponder = true
        alert.layout()
        return alert
    }

    /// Asks and answers true only for the yes button.
    @MainActor
    public static func ask(title: String, message: String, yes: String, no: String) -> Bool {
        let alert = make(title: title, message: message, yes: yes, no: no)
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
