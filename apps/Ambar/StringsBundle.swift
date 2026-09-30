import Foundation

extension Bundle {
    /// Cadenas de este módulo, resueltas también dentro del `.app` empaquetado.
    ///
    /// **No se puede usar `Bundle.module` a secas aquí**, y el motivo es concreto: el
    /// accesor que genera SwiftPM prueba
    /// `Bundle.main.bundleURL/Ambar_Ambar.bundle` —la **raíz** del `.app`, donde
    /// `codesign` no permite dejar nada: la rechaza con «unsealed contents present in
    /// the bundle root»— y, si falla, un `buildPath` **absoluto** al `.build` de la
    /// máquina que compiló. Si ninguna existe, hace `fatalError`.
    ///
    /// Con los bundles en `Contents/Resources` —el único sitio firmable— eso
    /// significaba que la app resolvía sus cadenas **solo en la máquina de
    /// compilación**, salvada por la ruta absoluta. En cualquier otro Mac moría al
    /// arrancar, en la primera cadena que resuelve el menú de la barra.
    ///
    /// El helper se duplica en cada módulo a propósito: son diez líneas, y la
    /// alternativa era que `AppCore` dependiera de un módulo de interfaz solo para
    /// esto.
    static let localized: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Ambar_Ambar.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        // Desarrollo, tests y `swift run`: el que resuelve SwiftPM.
        return .module
    }()
}
