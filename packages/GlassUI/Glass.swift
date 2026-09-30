import AppKit
import SwiftUI

/// Liquid Glass primitives.
///
/// These wrap `NSGlassEffectView` and `NSGlassEffectContainerView` (macOS 26) so
/// they can be used from SwiftUI. This lives in its own module because it is the
/// first thing another native app will want to reuse: it is the seed of a native
/// design system, with no code relationship to the monorepo's web design system —
/// here the colours come from the system, not from a palette of our own.
public enum Glass {
    /// Available styles. `clear` lets far more of the background through and is
    /// the right one when visual content (images) sits on top; `regular` is the
    /// one that keeps text legible.
    public enum Style: Sendable {
        case regular
        case clear

        var native: NSGlassEffectView.Style {
            switch self {
            case .regular: .regular
            case .clear: .clear
            }
        }
    }

    /// Builds the glass view that backs a window.
    ///
    /// It is used as the `contentView` of the `NSPanel`, with the SwiftUI
    /// hierarchy inside: that way the material samples what is behind the window,
    /// which is what produces the real effect instead of an imitation made out of
    /// transparency.
    @MainActor
    public static func makeWindowBackdrop(
        content: NSView,
        cornerRadius: CGFloat,
        style: Style = .regular
    ) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = style.native
        glass.cornerRadius = cornerRadius
        glass.contentView = content

        // `cornerRadius` rounds the MATERIAL, not the view. The glass view's own
        // layer stays a rectangle, and since this view is the window's
        // `contentView`, everything falling outside the material's shape
        // composites against the window backing: four dark wedges, one per corner.
        //
        // It is the same defect already fixed one layer in — the `NSHostingView`
        // clip in `PanelController.makePanel`, which carries its own comment about
        // exactly this — and that was missing from the parent. Masking to the same
        // radius is a no-op for the material, which already ends there, and
        // removes only what was being painted beyond it.
        glass.wantsLayer = true
        glass.layer?.cornerRadius = cornerRadius
        // `.continuous` is the system squircle curve. With the default circular
        // one the edge does not meet the material's and a one-pixel step shows
        // along each corner's diagonal.
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.backgroundColor = NSColor.clear.cgColor
        return glass
    }
}

// `GlassContainer` and `GlassSurface` (+ `View.glassSurface`) used to live here: two
// `NSViewRepresentable` bridges over `NSGlassEffectContainerView`/`NSGlassEffectView`.
//
// They were deleted for two reasons that reinforce each other. First: **nobody used
// them** — zero callers across `apps/`, `packages/`, `Tests/` and `Scripts/`. Second:
// they reimplemented API the SDK already provides for content that is already SwiftUI,
// `.glassEffect(_:in:)` (`SwiftUICore.swiftinterface:2592`) and `GlassEffectContainer`
// (`:9157`), and on top of that without being able to take part in the
// `glassEffectID`/`glassEffectUnion` merging that only works between SwiftUI views.
//
// `GlassContainer` also hid a latent defect: it assigned `container.contentView` and
// immediately read `hosting.superview` to activate constraints. The `NSGlassEffectView`
// header does not guarantee that `superview` is set synchronously; were it `nil`, the
// constraints would not activate and — with
// `translatesAutoresizingMaskIntoConstraints = false` — the view would end up at zero
// size. Invisible precisely because it had no callers.
//
// What IS kept is `Glass.makeWindowBackdrop`: an `NSPanel`'s backdrop has to sample
// what is **behind the window**, and SwiftUI's `.glassEffect` cannot do that. There
// AppKit is the right answer, and it is the only place where the bridge is justified.
