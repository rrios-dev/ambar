#if DEBUG

import AppCore
import AppKit
import ApplicationServices
import GlassUI
import SwiftUI

/// Rasteriza la interfaz a un PNG.
///
/// Existe para poder revisar la composición de forma automatizada:
/// `screencapture` y `CGWindowListCreateImage` exigen permiso de Grabación de
/// Pantalla, mientras que una app siempre puede dibujar sus propias vistas.
///
/// Se usa `ImageRenderer` y no `cacheDisplay(in:to:)` porque SwiftUI dibuja
/// sobre capas y el segundo devuelve un lienzo en blanco.
///
/// Aviso al mirar los resultados: el material Liquid Glass lo compone el
/// servidor de ventanas **fuera** del proceso, así que no aparece aquí. Estas
/// capturas sirven para verificar maquetación, textos y traducciones; el
/// cristal solo se puede juzgar en pantalla.
@MainActor
enum SelfCapture {
    /// Vuelca el estado de la jerarquía de la ventana real.
    ///
    /// El recorte de las esquinas y la transparencia del contenido no se pueden
    /// comprobar en una rasterización —ocurren en la composición de la ventana—
    /// pero sí se pueden inspeccionar en las capas. Esto convierte "parece que
    /// ya no se ven las esquinas negras" en una comprobación objetiva.
    static func diagnose(window: NSWindow) -> String {
        var lines: [String] = []

        // Lo primero que hay que mirar cuando "no pega": sin este permiso el
        // sistema descarta los eventos sintéticos en silencio.
        lines.append("accesibilidad.concedida  = \(AXIsProcessTrusted())")
        lines.append("bundle.id                = \(Bundle.main.bundleIdentifier ?? "sin identificador")")
        lines.append("bundle.ruta              = \(Bundle.main.bundlePath)")
        lines.append("firma                    = \(codeSignatureSummary())")
        lines.append("")

        lines.append("ventana.opaca            = \(window.isOpaque)")
        lines.append("ventana.fondo            = \(window.backgroundColor.description)")

        guard let backdrop = window.contentView else {
            return (lines + ["sin contentView"]).joined(separator: "\n")
        }

        lines.append("contentView              = \(type(of: backdrop))")

        if let glass = backdrop as? NSGlassEffectView {
            lines.append("cristal.cornerRadius     = \(glass.cornerRadius)")
            lines.append("cristal.style            = \(glass.style == .regular ? "regular" : "clear")")
            lines.append("cristal.contentView      = \(glass.contentView.map { String(describing: type(of: $0)) } ?? "nil")")

            if let hosting = glass.contentView, let layer = hosting.layer {
                lines.append("contenido.cornerRadius   = \(layer.cornerRadius)")
                lines.append("contenido.cornerCurve    = \(layer.cornerCurve.rawValue)")
                lines.append("contenido.masksToBounds  = \(layer.masksToBounds)")
                let background = layer.backgroundColor
                    .flatMap { NSColor(cgColor: $0)?.alphaComponent }
                lines.append("contenido.fondo.alpha    = \(background.map { "\($0)" } ?? "sin fondo")")
                lines.append("contenido.opaco          = \(layer.isOpaque)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Autoridad de firma del binario en ejecución.
    ///
    /// Importa porque macOS ata el permiso de accesibilidad a la firma: con
    /// firma ad-hoc (`adhoc`) el permiso se revoca en cada recompilación.
    private static func codeSignatureSummary() -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return "no se pudo leer" }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return "sin información" }

        if let flags = dictionary["flags"] as? UInt32, flags & 0x0000_0002 != 0 {
            return "ad-hoc (el permiso se revoca en cada compilación)"
        }
        if let authorities = dictionary["certificates"] as? [SecCertificate], let first = authorities.first {
            var common: CFString?
            SecCertificateCopyCommonName(first, &common)
            return (common as String?) ?? "certificado sin nombre"
        }
        return "sin firmar"
    }

    /// Rasteriza un paso de la presentación de primer uso.
    ///
    /// Aquí **no** hace falta una réplica como la del panel: el contenido de un paso ya es
    /// SwiftUI puro, y por eso `OnboardingStepView` y `OnboardingFooter` están separados de
    /// la ventana —lo único que se deja fuera es el `ScrollView`, que `ImageRenderer` no
    /// sabe rasterizar—. Lo que se ve aquí es, componente por componente, lo que se pinta.
    ///
    /// Excepciones conocidas y sin remedio: el grabador de atajos y los interruptores son
    /// vistas de AppKit —`NSSwitch`, y el grabador es propio— y `ImageRenderer` los pinta
    /// como un rectángulo amarillo con un símbolo de prohibido. En pantalla son controles
    /// normales; lo que estas capturas juzgan es la composición alrededor. El material de cristal tampoco aparece, como en el
    /// resto de capturas: lo compone el servidor de ventanas fuera del proceso.
    static func captureOnboarding(
        model: AppModel,
        step: OnboardingStep,
        relocation: AppRelocation.Decision,
        coordinator: OnboardingCoordinator,
        to path: String,
        colorScheme: ColorScheme = .dark
    ) -> Bool {
        let background = colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.97)
        // `maxHeight: .infinity` con la alineación del paso, y **no** un `Spacer` detrás del
        // contenido: con el Spacer la captura empujaba todo hacia arriba y mostraba una
        // portada descentrada que en la ventana real está centrada. Una captura que no
        // reproduce la composición sirve para comparar traducciones y para nada más — y se
        // usó para juzgar el diseño, que es peor que no tenerla.
        let view = VStack(spacing: 0) {
            OnboardingStepView(model: model, step: step, relocation: relocation)
                .padding(.horizontal, Metrics.Inset.pane)
                .padding(.vertical, Metrics.Spacing.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            Divider().opacity(0.5)
            OnboardingFooter(coordinator: coordinator)
        }
        .frame(width: Metrics.onboardingWidth, height: Metrics.onboardingHeight)
        .background(background)
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else { return false }

        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    static func captureInterface(
        model: AppModel,
        controller: PanelController,
        to path: String,
        colorScheme: ColorScheme = .dark
    ) -> Bool {
        // `ImageRenderer` no rasteriza `ScrollView` ni los campos de texto —
        // ambos delegan en vistas de AppKit que solo existen dentro de una
        // ventana real. Para revisar la maquetación se compone una réplica con
        // los mismos componentes sobre contenedores estáticos.
        let view = CaptureSheet(model: model, colorScheme: colorScheme)
            .environment(\.colorScheme, colorScheme)
            .frame(width: Metrics.panelWidth, height: Metrics.panelHeight)

        let renderer = ImageRenderer(content: view)
        // 2× para revisar la nitidez del texto igual que en una pantalla Retina.
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else { return false }

        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }
}

/// Réplica estática del panel para las capturas de revisión.
///
/// Usa exactamente los mismos componentes que el panel real —`HistoryRow`,
/// `PreviewPane`— para que lo que se ve aquí sea lo que se verá en pantalla;
/// lo único que cambia son los contenedores que `ImageRenderer` no sabe
/// rasterizar.
private struct CaptureSheet: View {
    let model: AppModel
    let colorScheme: ColorScheme

    private var background: Color {
        colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.97)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.Spacing.regular) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(String(localized: "search.placeholder", bundle: .localized))
                    .font(.system(size: 19))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, Metrics.Spacing.loose)
            .frame(height: 54)

            Divider().opacity(0.5)

            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(Array(model.items.prefix(8).enumerated()), id: \.element.id) { index, item in
                        HistoryRow(
                            item: item,
                            thumbnail: model.thumbnail(for: item),
                            isSelected: index == model.selectedIndex
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.Spacing.snug)
                .padding(.vertical, Metrics.Spacing.snug)
                .frame(width: 320)

                Divider().opacity(0.5)

                PreviewPane(model: model, scrollable: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().opacity(0.5)

            HStack(spacing: Metrics.Spacing.loose) {
                CaptureHint(keys: "↵", label: String(localized: "hint.paste", bundle: .localized))
                CaptureHint(keys: "⌘↵", label: String(localized: "hint.paste_plain", bundle: .localized))
                CaptureHint(keys: "⌘P", label: String(localized: "hint.pin", bundle: .localized))
                CaptureHint(keys: "⌘⌫", label: String(localized: "hint.delete", bundle: .localized))
                Spacer()
                Text("\(model.items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Metrics.Spacing.loose)
            .frame(height: 30)
        }
        .background(background)
    }
}

private struct CaptureHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: Metrics.Spacing.tight) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

#endif
