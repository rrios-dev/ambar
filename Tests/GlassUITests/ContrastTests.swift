import AppKit
import SwiftUI
import Testing

@testable import GlassUI

/// Luminancia relativa según WCAG 2.1, §Relative luminance.
private func relativeLuminance(_ color: NSColor) -> Double {
    guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
    func channel(_ value: CGFloat) -> Double {
        let v = Double(value)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(srgb.redComponent)
        + 0.7152 * channel(srgb.greenComponent)
        + 0.0722 * channel(srgb.blueComponent)
}

/// Compone un color con alfa sobre un fondo opaco.
///
/// Necesario porque los colores semánticos de macOS son blancos o negros con
/// alfa: su contraste real solo existe una vez compuestos.
private func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
    guard let f = foreground.usingColorSpace(.sRGB),
          let b = background.usingColorSpace(.sRGB)
    else { return foreground }
    let a = f.alphaComponent
    return NSColor(
        srgbRed: f.redComponent * a + b.redComponent * (1 - a),
        green: f.greenComponent * a + b.greenComponent * (1 - a),
        blue: f.blueComponent * a + b.blueComponent * (1 - a),
        alpha: 1
    )
}

private func contrastRatio(_ foreground: NSColor, on background: NSColor) -> Double {
    let a = relativeLuminance(composite(foreground, over: background))
    let b = relativeLuminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// Las cuatro apariencias en las que puede ejecutarse la app.
///
/// **Ojo, medido**: en macOS 26 `AccessibilityHighContrastDarkAqua` resuelve a la MISMA
/// paleta que `AccessibilityHighContrastAqua` —`labelColor` negro al 0,85 y fondo `#ECECEC`
/// en las dos—, así que este bucle mide **tres** paletas y no cuatro. Se dejó de contar
/// cuatro cuando la ronda 7 lo destapó, y hay un test que lo afirma
/// (`highContrastDarkResolvesToTheLightPalette`): si un día el sistema las separa, ese test
/// falla y hay que volver a mirar la combinación oscuro + alto contraste, que hoy **no se
/// mide en ninguna parte**.
private let appearances = [
    "NSAppearanceNameDarkAqua",
    "NSAppearanceNameAqua",
    "NSAppearanceNameAccessibilityHighContrastDarkAqua",
    "NSAppearanceNameAccessibilityHighContrastAqua",
]

/// Las opacidades **reales** del módulo, no una réplica.
///
/// Antes eran constantes locales que replicaban los valores de `TextStyles.swift`, y
/// eso hacía la comprobación inútil: bajar la opacidad real a 0,25 dejaba estos tests
/// en verde, porque medían fielmente una copia de algo que ya no existía.
private let informationalAlpha = Color.Opacity.informational
private let informationalStrongAlpha = Color.Opacity.informationalStrong

/// Compone **exactamente como lo hace la app**, y esto es una cicatriz.
///
/// Los tests usaban `NSColor.labelColor.withAlphaComponent(x)`, que **sustituye** el alfa.
/// La app usa `Color(nsColor: .labelColor).opacity(x)`, que lo **multiplica** — y
/// `labelColor` ya viene a 0,847. Medido: con 0,60 el test certificaba un alfa de 0,600
/// mientras la pantalla dibujaba 0,508, o sea **4,09:1 en apariencia clara**, por debajo de
/// AA, con el test en verde y la tabla del módulo afirmando 5,46:1 en el peor caso.
///
/// Tercera variante del mismo fallo de método: la ronda 8 quitó las constantes replicadas y
/// dejó una **regla de composición** distinta de la que usa SwiftUI. Se mide lo que se
/// dibuja o no se mide nada.
@MainActor
private func rendered(_ color: Color) -> NSColor {
    NSColor(color)
}

/// Nota de método, de la ronda 8: estas medidas usaban `windowBackgroundColor`, que **solo
/// es el fondo real cuando «Reducir transparencia» está activo**. El panel es un
/// `NSGlassEffectView`, así que el fondo compuesto depende del escritorio de cada persona, y
/// el propio `SelfCapture` documenta que ese cristal lo compone el servidor de ventanas fuera
/// del proceso —no sale en una rasterización—.
///
/// Consecuencia medida: `informational` necesita un fondo compuesto de ~0,76 de gris para
/// llegar a 4,5:1, y sobre gris medio da 2,99:1. Eso **no** es una violación probada (no se
/// puede saber cuánta luz deja pasar el material), pero sí significa que la afirmación de §5
/// estaba verificada contra un fondo que la app casi nunca tiene. La suite mide ahora las dos
/// cosas por separado: el caso opaco garantizado y la sensibilidad al fondo.
@Suite("Contraste de texto (WCAG 2.1 AA)")
struct ContrastTests {

    /// 4,5:1 es el mínimo para texto normal. Todo el texto informativo de Ámbar
    /// está entre 10 y 11 px, muy por debajo del umbral de «texto grande», así
    /// que no le vale el 3:1 relajado.
    static let minimumAA = 4.5

    @Test("El texto informativo cumple AA en las cuatro apariencias")
    @MainActor
    func informationalMeetsAA() {
        for name in appearances {
            guard let appearance = NSAppearance(named: NSAppearance.Name(name))
            else { continue }
            appearance.performAsCurrentDrawingAppearance {
                let color = rendered(Color(nsColor: .labelColor).opacity(informationalAlpha))
                let ratio = contrastRatio(color, on: .windowBackgroundColor)

                #expect(
                    ratio >= Self.minimumAA,
                    "\(name): \(String(format: "%.2f", ratio)):1 — por debajo de 4,5:1"
                )
            }
        }
    }

    @Test("El texto informativo reforzado cumple AA en las cuatro apariencias")
    @MainActor
    func informationalStrongMeetsAA() {
        for name in appearances {
            guard let appearance = NSAppearance(named: NSAppearance.Name(name))
            else { continue }
            appearance.performAsCurrentDrawingAppearance {
                let color = rendered(Color(nsColor: .labelColor).opacity(informationalStrongAlpha))
                let ratio = contrastRatio(color, on: .windowBackgroundColor)

                #expect(ratio >= Self.minimumAA, "\(name): \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// 3:1 es el mínimo de WCAG 2.1 §1.4.11 para componentes de interfaz que no son
    /// texto —el 4,5:1 de arriba es para texto—. `trackFill` medía 1,41–1,63:1: por
    /// debajo, y sin ningún test que lo protegiera hasta esta ronda.
    static let minimumNonTextAA = 3.0

    @Test("El carril del indicador de progreso cumple el contraste no textual en las cuatro apariencias")
    @MainActor
    func trackFillMeetsNonTextAA() {
        // Los dos valores directamente, no `Color.trackFill` en vivo: esa propiedad lee
        // `AccessibilityPreferences.shared.increaseContrast`, un singleton compartido con
        // otras suites que no serializan contra esta — tocarlo aquí sería la misma
        // fragilidad que ya se documentó en otras rondas de este fichero.
        for name in appearances {
            guard let appearance = NSAppearance(named: NSAppearance.Name(name))
            else { continue }
            appearance.performAsCurrentDrawingAppearance {
                for (label, alpha) in [
                    ("normal", Color.Opacity.trackFill),
                    ("alto contraste", Color.Opacity.trackFillHighContrast),
                ] {
                    let color = rendered(Color(nsColor: .labelColor).opacity(alpha))
                    let ratio = contrastRatio(color, on: .windowBackgroundColor)
                    #expect(
                        ratio >= Self.minimumNonTextAA,
                        "\(label) en \(name): \(String(format: "%.2f", ratio)):1 — por debajo de 3:1 (WCAG 1.4.11)"
                    )
                }
            }
        }
    }

    /// El par de selección del sistema tiene un techo propio: medido,
    /// `alternateSelectedControlTextColor` sobre `selectedContentBackgroundColor` da
    /// **4,02:1** con «Aumentar contraste», incluso a opacidad plena. No llega a 4,5 y no
    /// se puede subir sin sustituir los colores de selección de macOS, con lo que la
    /// selección dejaría de parecerse a la del resto del sistema.
    ///
    /// El umbral relajado documenta ESE techo, y solo ese. Lo que no puede hacer —y hacía
    /// hasta esta ronda— es tapar además una degradación **nuestra** encima: el subtítulo
    /// se pintaba al 0,75 y bajaba a 2,89:1, y este test no lo veía porque medía solo el
    /// título.
    static let selectionCeiling = 4.0

    @Test("El texto sobre la selección cumple el techo del par del sistema")
    @MainActor
    func selectionTextMeetsAA() {
        for name in appearances {
            guard let appearance = NSAppearance(named: NSAppearance.Name(name)) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                let ratio = contrastRatio(
                    .alternateSelectedControlTextColor,
                    on: .selectedContentBackgroundColor
                )
                #expect(ratio >= Self.selectionCeiling, "\(name): \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// El subtítulo de la fila seleccionada, que es lo que nadie medía.
    ///
    /// Siempre hay exactamente una fila seleccionada y es la que el usuario va a pegar, así
    /// que este texto está permanentemente en pantalla.
    @Test("El subtítulo de la fila seleccionada no empeora el par del sistema")
    @MainActor
    func selectedSubtitleDoesNotDegradeTheSystemPair() {
        for name in appearances {
            guard let appearance = NSAppearance(named: NSAppearance.Name(name)) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                let title = contrastRatio(
                    .alternateSelectedControlTextColor,
                    on: .selectedContentBackgroundColor
                )
                let isHighContrast = name.contains("HighContrast")
                let alpha = isHighContrast
                    ? Color.Opacity.selectedSecondaryHighContrast
                    : Color.Opacity.selectedSecondary
                let subtitle = contrastRatio(
                    rendered(Color(nsColor: .alternateSelectedControlTextColor).opacity(alpha)),
                    on: .selectedContentBackgroundColor
                )

                // Con «Aumentar contraste» no se atenúa nada: el subtítulo iguala al
                // título, que es el techo del sistema. Sin él, hay margen para atenuar y
                // aun así cumplir AA de texto.
                if isHighContrast {
                    #expect(
                        subtitle >= title - 0.01,
                        "\(name): el subtítulo (\(String(format: "%.2f", subtitle))) empeora el techo del sistema (\(String(format: "%.2f", title)))"
                    )
                } else {
                    #expect(
                        subtitle >= Self.minimumAA,
                        "\(name): subtítulo seleccionado a \(String(format: "%.2f", subtitle)):1, bajo 4,5"
                    )
                }
            }
        }
    }

    @Test("Los estilos jerárquicos del sistema no valen para texto pequeño")
    @MainActor
    func hierarchicalStylesWouldFail() {
        // Documenta por qué existe `Color.informational`. Si algún día Apple
        // sube el contraste de estos colores y este test empieza a fallar,
        // será señal de que se puede volver a `.secondary`/`.tertiary` —
        // no de que haya que silenciarlo.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            #expect(contrastRatio(.tertiaryLabelColor, on: .windowBackgroundColor) < 4.5)
            #expect(contrastRatio(.secondaryLabelColor, on: .windowBackgroundColor) < 4.5)
        }
    }
}

/// La rama de «Aumentar contraste», que no se medía nunca.
///
/// Importa porque es exactamente donde la auditoría de agosto encontró el fallo: los
/// colores del sistema **empeoran** con ese ajuste. Los tokens propios tienen que ir al
/// revés, y eso hay que comprobarlo, no suponerlo.
/// Nota de método, de la ronda 8: estas medidas usaban `windowBackgroundColor`, que **solo
/// es el fondo real cuando «Reducir transparencia» está activo**. El panel es un
/// `NSGlassEffectView`, así que el fondo compuesto depende del escritorio de cada persona, y
/// el propio `SelfCapture` documenta que ese cristal lo compone el servidor de ventanas fuera
/// del proceso —no sale en una rasterización—.
///
/// Consecuencia medida: `informational` necesita un fondo compuesto de ~0,76 de gris para
/// llegar a 4,5:1, y sobre gris medio da 2,99:1. Eso **no** es una violación probada (no se
/// puede saber cuánta luz deja pasar el material), pero sí significa que la afirmación de §5
/// estaba verificada contra un fondo que la app casi nunca tiene. La suite mide ahora las dos
/// cosas por separado: el caso opaco garantizado y la sensibilidad al fondo.
@Suite("Contraste con «Aumentar contraste»")
struct HighContrastTokenTests {

    @Test("las opacidades de alto contraste cumplen AA en las cuatro apariencias")
    @MainActor
    func highContrastOpacitiesMeetAA() {
        // `rendered(...)`, no `NSColor.withAlphaComponent`: esa sustituye el alfa en vez
        // de multiplicarlo, que es como compone `Color(nsColor:).opacity(_:)` de verdad.
        // Es la misma trampa de método que costó una violación de AA sin detectar en la
        // ronda 8 —aquí no llegó a morder porque otro test acota el factor por otro
        // lado, medido por la auditoría de ronda 12— y esta suite era la única que
        // seguía componiendo distinto de como dibuja la app.
        for name in appearances {
            guard let appearance = NSAppearance(named: NSAppearance.Name(name))
            else { continue }
            appearance.performAsCurrentDrawingAppearance {
                for (label, alpha) in [
                    ("informational", Color.Opacity.informationalHighContrast),
                    ("informationalStrong", Color.Opacity.informationalStrongHighContrast),
                ] {
                    let color = rendered(Color(nsColor: .labelColor).opacity(alpha))
                    let ratio = contrastRatio(color, on: .windowBackgroundColor)
                    #expect(
                        ratio >= 4.5,
                        "\(label) en \(name): \(String(format: "%.2f", ratio)):1 — bajo 4,5:1"
                    )
                }
            }
        }
    }

    @Test("el ajuste sube el contraste, no lo baja")
    @MainActor
    func increasedContrastActuallyIncreases() {
        for name in appearances {
            guard let appearance = NSAppearance(named: NSAppearance.Name(name))
            else { continue }
            appearance.performAsCurrentDrawingAppearance {
                let normal = contrastRatio(
                    rendered(Color(nsColor: .labelColor).opacity(Color.Opacity.informational)),
                    on: .windowBackgroundColor
                )
                let raised = contrastRatio(
                    rendered(Color(nsColor: .labelColor).opacity(Color.Opacity.informationalHighContrast)),
                    on: .windowBackgroundColor
                )
                #expect(
                    raised > normal,
                    "\(name): alto contraste \(String(format: "%.2f", raised)):1 frente a \(String(format: "%.2f", normal)):1"
                )
            }
        }
    }
}

/// Cuántas paletas distintas hay de verdad.
///
/// La suite recorría cuatro nombres de apariencia y daba por hecho cuatro medidas. Dos de
/// ellos resuelven a la misma paleta, así que la tabla de `TextStyles.swift` tenía dos
/// columnas idénticas presentadas como mediciones independientes — y la combinación que de
/// verdad falta, oscuro + «Aumentar contraste», no se mide en ninguna parte.
///
/// Afirmarlo tiene dos efectos: la tabla deja de mentir, y si un día el sistema separa las
/// paletas este test falla y obliga a volver a mirar.
@Suite("Cuántas paletas hay de verdad")
@MainActor
struct AppearancePaletteTests {

    static func palette(_ name: String) -> (label: Double, background: Double)? {
        guard let appearance = NSAppearance(named: NSAppearance.Name(name)) else { return nil }
        var result: (Double, Double)?
        appearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor.usingColorSpace(.sRGB)
            let background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            result = (
                Double(label?.brightnessComponent ?? -1),
                Double(background?.brightnessComponent ?? -1)
            )
        }
        return result
    }

    @Test("la de alto contraste oscura resuelve a la paleta clara")
    func highContrastDarkResolvesToTheLightPalette() throws {
        let light = try #require(Self.palette("NSAppearanceNameAccessibilityHighContrastAqua"))
        let dark = try #require(Self.palette("NSAppearanceNameAccessibilityHighContrastDarkAqua"))

        // Si esto empieza a fallar, es una buena noticia: significa que el sistema las ha
        // separado y que hay una cuarta paleta real que medir.
        #expect(
            abs(light.label - dark.label) < 0.001 && abs(light.background - dark.background) < 0.001,
            "las paletas de alto contraste se han separado: hay que medir la oscura"
        )
    }

    @Test("clara y oscura sí son distintas")
    func lightAndDarkDiffer() throws {
        let light = try #require(Self.palette("NSAppearanceNameAqua"))
        let dark = try #require(Self.palette("NSAppearanceNameDarkAqua"))
        // Control del propio método: si esto no distinguiera, la medición no valdría nada.
        #expect(abs(light.background - dark.background) > 0.5)
    }
}

/// Que el alfa **dibujado** sea el que se pretende.
///
/// La trampa que costó una violación de AA silenciosa: `Color(nsColor:).opacity(x)`
/// multiplica por el alfa que ya trae `labelColor`, así que un 0,60 «para un 60 %» dibujaba
/// 0,508. Los tests de contraste lo miden ahora componiendo igual que la app, pero eso solo
/// se ve como un ratio; aquí se compara alfa contra alfa, que es donde el error se lee de un
/// vistazo.
@Suite("El alfa dibujado es el pretendido")
struct RenderedAlphaTests {

    /// Alfa que trae `labelColor` de fábrica. Medido en macOS 26, y es lo que convierte una
    /// opacidad en un factor en vez de un valor final.
    static let labelAlpha = 0.847

    @MainActor
    static func renderedAlpha(_ opacity: Double) -> Double {
        Double(NSColor(Color(nsColor: .labelColor).opacity(opacity)).alphaComponent)
    }

    @Test("el token informativo dibuja alrededor de 0,60")
    @MainActor
    func informationalRendersAsIntended() {
        let alpha = Self.renderedAlpha(Color.Opacity.informational)
        #expect(abs(alpha - 0.60) < 0.02, "dibuja \(String(format: "%.3f", alpha)), no 0,60")
    }

    @Test("el reforzado dibuja alrededor de 0,75")
    @MainActor
    func strongRendersAsIntended() {
        let alpha = Self.renderedAlpha(Color.Opacity.informationalStrong)
        #expect(abs(alpha - 0.75) < 0.02, "dibuja \(String(format: "%.3f", alpha)), no 0,75")
    }

    @Test("y con «Aumentar contraste» los dos suben de verdad")
    @MainActor
    func highContrastActuallyRaisesTheRenderedAlpha() {
        // Lo que importa no es el número de la constante sino lo que acaba en pantalla:
        // subir el factor sin mirar el alfa dibujado fue exactamente el fallo.
        #expect(
            Self.renderedAlpha(Color.Opacity.informationalHighContrast)
                > Self.renderedAlpha(Color.Opacity.informational)
        )
        #expect(
            Self.renderedAlpha(Color.Opacity.informationalStrongHighContrast)
                > Self.renderedAlpha(Color.Opacity.informationalStrong)
        )
    }

    @Test("`labelColor` sigue sin ser opaco, que es la razón de todo esto")
    @MainActor
    func labelColorIsNotOpaque() {
        // Si un día Apple lo hiciera opaco, los factores de arriba pasarían a dibujar más de
        // lo previsto y este test lo diría en vez de dejarlo pasar.
        let alpha = Double(NSColor.labelColor.usingColorSpace(.sRGB)?.alphaComponent ?? 1)
        #expect(abs(alpha - Self.labelAlpha) < 0.01, "labelColor dibuja a \(alpha)")
    }
}



/// Sobre cuántos fondos aguanta cada estilo — la medida que la nota de método prometía.
///
/// La cabecera de `ContrastTests` decía que la suite mide «el caso opaco garantizado y la
/// sensibilidad al fondo». Lo primero era cierto; lo segundo no lo medía nadie. Una nota
/// que promete una medición inexistente es peor que no tenerla: el siguiente lector cree
/// que el asunto está cubierto y no vuelve a mirar.
///
/// Por qué hace falta: el panel es un `NSGlassEffectView` y el fondo compuesto depende del
/// escritorio de cada persona. No se puede saber cuánta luz deja pasar el material, así que
/// **no se puede afirmar** que un estilo cumpla AA sobre el cristal. Lo que sí se puede
/// medir, y es lo que importa para no empeorar, es la **holgura**: sobre qué fracción de
/// fondos grises posibles el estilo sigue cumpliendo.
///
/// La afirmación no es «cumple AA siempre» —sería mentira— sino «no se ha vuelto más
/// frágil que cuando se midió». Bajar una opacidad reduce la cobertura y lo pone en rojo.
@Suite("Cuánta holgura tiene cada estilo frente al fondo")
@MainActor
struct BackgroundSensitivityTests {

    /// Fracción de grises de 0 a 1 sobre los que `color` cumple el mínimo.
    ///
    /// Grises y no colores arbitrarios porque es lo que hace la medida comparable entre
    /// apariencias y reproducible: un barrido por todo el espacio sRGB daría un número que
    /// nadie puede volver a obtener a mano.
    static func grayCoverage(_ color: NSColor, minimum: Double = ContrastTests.minimumAA) -> Double {
        let steps = 101
        var passing = 0
        for step in 0..<steps {
            let level = CGFloat(step) / CGFloat(steps - 1)
            let background = NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
            if contrastRatio(color, on: background) >= minimum { passing += 1 }
        }
        return Double(passing) / Double(steps)
    }

    static func coverage(appearance name: String, alpha: Double) -> Double? {
        guard let appearance = NSAppearance(named: NSAppearance.Name(name)) else { return nil }
        var result: Double?
        appearance.performAsCurrentDrawingAppearance {
            result = grayCoverage(rendered(Color(nsColor: .labelColor).opacity(alpha)))
        }
        return result
    }

    /// Cobertura medida hoy del estilo informativo: **0,287**. Cumple AA sobre poco menos
    /// de un tercio de los grises posibles.
    ///
    /// El número sale igual en las cuatro apariencias, y no es un error de método: en la
    /// clara el texto es casi negro y aguanta los fondos claros, en la oscura es casi
    /// blanco y aguanta los oscuros. La fracción es simétrica.
    ///
    /// Que sea bajo no prueba una violación —no se puede saber cuánta luz deja pasar el
    /// cristal—, pero sí dice que este estilo es el primero que caería si el material se
    /// vuelve más translúcido, y que no hay margen para bajarle la opacidad.
    static let informationalBaseline = 0.28

    /// Cobertura medida del estilo fuerte: 0,366 en oscuro, 0,465 en el resto.
    static let strongBaseline = 0.36

    @Test("el texto informativo no se ha vuelto más frágil de lo medido")
    func informationalKeepsItsMargin() throws {
        for name in appearances {
            guard let coverage = Self.coverage(appearance: name, alpha: informationalAlpha) else { continue }

            #expect(
                coverage >= Self.informationalBaseline,
                "el texto informativo aguanta menos fondos que cuando se midió: \(coverage) < \(Self.informationalBaseline) en \(name)"
            )
        }
    }

    @Test("y el estilo fuerte tampoco")
    func strongKeepsItsMargin() throws {
        for name in appearances {
            guard let coverage = Self.coverage(appearance: name, alpha: informationalStrongAlpha) else { continue }

            #expect(
                coverage >= Self.strongBaseline,
                "el estilo fuerte aguanta menos fondos que cuando se midió: \(coverage) < \(Self.strongBaseline) en \(name)"
            )
        }
    }

    @Test("y el fuerte tiene más holgura que el normal: si no, la jerarquía está al revés")
    func strongHasMoreMarginThanInformational() throws {
        for name in appearances {
            guard let weak = Self.coverage(appearance: name, alpha: informationalAlpha),
                  let strong = Self.coverage(appearance: name, alpha: informationalStrongAlpha)
            else { continue }
            #expect(strong >= weak, "el estilo fuerte aguanta menos fondos que el normal en \(name)")
        }
    }
}

/// El texto de la banda de dictado, sobre el fondo que la banda **sí** tiene.
///
/// Hallazgo de la auditoría de cierre: `ContrastTests` mide contra `.windowBackgroundColor`,
/// pero `DictationBanner` no pinta sobre eso — pinta sobre el panel con una capa propia de
/// `labelColor` al 0,06, que sube a 0,14 con «Aumentar contraste»
/// (`DictationBanner.swift:104`). No era un defecto de contraste, sino una comprobación
/// que no cubría el caso real: nadie medía el fondo de la superficie donde vive el texto
/// del dictado, que es la superficie nueva de toda esta función.
///
/// La capa **oscurece** en apariencia clara y **aclara** en oscura, así que en los dos
/// casos empuja el fondo hacia el texto y podría comerse el margen. Por eso se mide.
@Suite("Contraste de la banda de dictado, sobre su fondo real")
@MainActor
struct DictationBannerContrastTests {

    /// Las dos opacidades **reales**, leídas del sistema de diseño.
    ///
    /// Estaban replicadas aquí como literales, y por eso este suite no protegía nada:
    /// cambiar la opacidad de la banda a 0,55/0,60 dejaba las 480 pruebas en verde con el
    /// contraste real en **1,95:1**. Medía una copia — el mismo fallo que la cabecera de
    /// `TextStyles` documenta y que este suite decía venir a arreglar.
    static let layerAlphas: [(label: String, alpha: Double)] = [
        ("normal", Color.Opacity.bannerLayer(increaseContrast: false)),
        ("Aumentar contraste", Color.Opacity.bannerLayer(increaseContrast: true)),
    ]

    /// El fondo que ve el texto: la capa de la banda compuesta sobre el fondo del panel.
    static func bannerBackground(alpha: Double) -> NSColor {
        composite(NSColor.labelColor.withAlphaComponent(alpha), over: .windowBackgroundColor)
    }

    @Test("el texto de la banda cumple AA sobre la capa que la banda pinta")
    func bannerTextMeetsAAOnItsOwnBackground() {
        for name in appearances {
            guard let appearance = NSAppearance(named: NSAppearance.Name(name)) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                for layer in Self.layerAlphas {
                    let text = rendered(Color(nsColor: .labelColor).opacity(informationalAlpha))
                    let ratio = contrastRatio(text, on: Self.bannerBackground(alpha: layer.alpha))

                    #expect(
                        ratio >= ContrastTests.minimumAA,
                        "la banda de dictado baja de AA en \(name) con la capa \(layer.label): \(ratio)"
                    )
                }
            }
        }
    }

    @Test("y la capa de «Aumentar contraste» no se come el margen")
    func theHighContrastLayerDoesNotEatTheMargin() {
        // El ajuste que sube la opacidad de la capa existe para marcar mejor la banda. Si
        // al hacerlo empeorara el contraste del texto de dentro, estaría perjudicando
        // exactamente a quien lo activó — que es el fallo que ya se cometió una vez con
        // las opacidades de `TextStyles`.
        for name in appearances {
            guard let appearance = NSAppearance(named: NSAppearance.Name(name)) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                let text = rendered(Color(nsColor: .labelColor).opacity(informationalAlpha))
                let normal = contrastRatio(
                    text, on: Self.bannerBackground(alpha: Color.Opacity.bannerLayer(increaseContrast: false))
                )
                let raised = contrastRatio(
                    text, on: Self.bannerBackground(alpha: Color.Opacity.bannerLayer(increaseContrast: true))
                )

                #expect(
                    raised >= ContrastTests.minimumAA,
                    "con «Aumentar contraste» la banda baja de AA en \(name): \(raised) (sin él, \(normal))"
                )
            }
        }
    }
}
