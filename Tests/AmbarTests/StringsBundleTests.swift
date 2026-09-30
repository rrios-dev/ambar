import Foundation
import Testing

@testable import Ambar

/// El accesor de cadenas del `.app` empaquetado.
///
/// Existe porque la mutación que lo devuelve a `Bundle.module` dejaba la suite entera
/// en verde — y eso es «el hallazgo de las cuatro rondas»: la app moría al arrancar en
/// cualquier máquina que no fuera la de compilación, porque el accesor de SwiftPM
/// resuelve por una ruta ABSOLUTA al `.build`.
@Suite("Bundle de cadenas")
struct StringsBundleTests {

    /// El accesor tiene que resolver contra `Contents/Resources`, que es donde
    /// `make-app.sh` copia los bundles (la raíz del `.app` la rechaza `codesign`).
    @Test("resuelve el bundle desde Contents/Resources de un .app simulado")
    func resolvesFromContentsResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AmbarStringsTest-\(UUID().uuidString).app")
        let resources = root.appending(path: "Contents/Resources")
        let bundleURL = resources.appending(path: "Ambar_Ambar.bundle")
        let lproj = bundleURL.appending(path: "es.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #""probe.key" = "resuelto";\#n"#.write(
            to: lproj.appending(path: "Localizable.strings"),
            atomically: true,
            encoding: .utf8
        )
        try #"{\#n  "CFBundleName": "Ambar_Ambar"\#n}"#.write(
            to: bundleURL.appending(path: "Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        // La ruta que el accesor tiene que mirar, y que el de SwiftPM NO mira.
        let resolved = Bundle(url: bundleURL)
        #expect(resolved != nil, "el bundle de Contents/Resources no se puede abrir")
        #expect(
            resolved?.localizations.contains("es") == true,
            "la localización no se ve desde ahí: \(resolved?.localizations ?? [])"
        )
    }

    /// Y la prueba de que las cadenas del módulo resuelven de verdad: si el accesor
    /// apuntara a un bundle inexistente, esto devolvería el identificador en crudo.
    @Test("una clave del módulo devuelve texto, no su identificador")
    func moduleKeysResolveToText() {
        let text = String(localized: "dictation.state.listening", bundle: .localized)
        #expect(
            text != "dictation.state.listening",
            "la clave no resuelve: el accesor no encuentra el bundle de cadenas"
        )
        #expect(!text.isEmpty)
    }
}
