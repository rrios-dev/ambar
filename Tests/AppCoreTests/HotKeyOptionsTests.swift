import Carbon.HIToolbox
import Testing

@testable import AppCore

/// Registration with options reports Carbon's status instead of dropping it, and the
/// call without options keeps working exactly as before.
@Suite("Hot key registration with options", .serialized)
@MainActor
struct HotKeyOptionsTests {
    /// ⌃⌥⇧⌘F18: absent from laptop keyboards and with all four modifiers, so it cannot
    /// collide with anything the user presses, or with another app's real shortcut.
    static let harmless = KeyCombination(
        keyCode: UInt32(kVK_F18),
        modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
    )

    @Test("an exclusive registration of a free combination succeeds and can be removed")
    func exclusiveRegistration() throws {
        let identifier = try HotKeyCenter.shared.register(Self.harmless, options: .exclusive, action: {}).get()
        HotKeyCenter.shared.unregister(identifier)
        // Released: it can be taken again.
        let again = try HotKeyCenter.shared.register(Self.harmless, options: .exclusive, action: {}).get()
        HotKeyCenter.shared.unregister(again)
    }

    @Test("the call without options still returns an identifier")
    func legacyCallUnchanged() throws {
        let identifier = try #require(HotKeyCenter.shared.register(Self.harmless, action: {}))
        HotKeyCenter.shared.unregister(identifier)
    }

    @Test("a refusal keeps Carbon's status, and names an exclusive owner")
    func errorCarriesStatus() {
        #expect(HotKeyRegistrationError(status: OSStatus(eventHotKeyExistsErr)).isInUseByAnotherApp)
        #expect(!HotKeyRegistrationError(status: OSStatus(eventHotKeyInvalidErr)).isInUseByAnotherApp)
        #expect(HotKeyOptions.exclusive.rawValue == UInt32(kEventHotKeyExclusive))
    }
}
