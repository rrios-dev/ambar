import Foundation
import Testing
import VoiceKit

@testable import Ambar

/// Lo que la banda del dictado **dice** en cada estado.
///
/// Es la capa que una auditoría por mutación midió con poder de detección **cero**: borrar el
/// botón de parar, cambiar el gate que pinta la banda o dejar el rótulo en el genérico no
/// rompía ningún test. Y es donde vivieron las dos peores regresiones del proyecto.
///
/// Antes de esto se intentó montar la vista en un `NSHostingView` e inspeccionar el árbol de
/// accesibilidad: **sale vacío en un proceso de test**, así que las aserciones pasaban sin
/// mirar nada. Se cambió de método en lugar de quedarse con ese verde.
@Suite("Contenido de la banda del dictado")
@MainActor
struct BannerContentTests {

    static func content(
        _ state: DictationSessionState,
        failure: DictationFailure? = nil,
        liveText: String = "",
        volatile: Bool = false,
        hasSystemSettingsURL: Bool = true
    ) -> DictationBannerContent {
        DictationBannerContent.resolve(
            state: state,
            liveText: liveText,
            liveTextIsVolatile: volatile,
            failure: failure,
            hasSystemSettingsURL: hasSystemSettingsURL
        )
    }

    // MARK: - Controles ofrecidos

    @Test("mientras se escucha se ofrece parar, siempre")
    func listeningOffersStop() {
        // Es la única salida visible cuando el gesto no puede terminar: una tecla enclavada
        // por Teclas Especiales, o un teclado que reporta un modificador hundido. Sin ella,
        // el micrófono se queda abierto sin ninguna forma de cerrarlo.
        #expect(Self.content(.listening).controls.contains(.stop))
    }

    @Test("en la cuenta y en la preparación se puede descartar, pero no parar")
    func activeStatesOfferDiscard() {
        for state in [
            DictationSessionState.arming(progress: 0.5, prepared: false),
            .preparing,
            .finalizing,
        ] {
            let controls = Self.content(state).controls
            #expect(controls.contains(.discard), "sin salida en \(state)")
            // «Parar» ahí sugeriría que sigue grabando, y el micrófono no está abierto.
            #expect(!controls.contains(.stop), "ofreció parar con el micrófono cerrado en \(state)")
        }
    }

    @Test("el fallo del permiso lleva al panel del sistema")
    func permissionFailureLeadsToSystemSettings() {
        let controls = Self.content(.failed(.permissionDenied), failure: .permissionDenied).controls
        #expect(controls.contains(.openSystemSettings))
        #expect(controls.contains(.dismissFailure), "un aviso sin cerrar se queda hasta reabrir")
    }

    @Test("sin URL del panel del sistema no se ofrece un botón que no lleva a nada")
    func withoutSystemSettingsURLNoButton() {
        let controls = Self.content(
            .failed(.permissionDenied),
            failure: .permissionDenied,
            hasSystemSettingsURL: false
        ).controls
        #expect(!controls.contains(.openSystemSettings))
    }

    @Test("el modelo ausente lleva a Ajustes de Ámbar, que es donde se instala")
    func missingModelLeadsToAppSettings() {
        let controls = Self.content(.failed(.modelUnavailable), failure: .modelUnavailable).controls
        #expect(controls.contains(.openAppSettings))
    }

    @Test("el cupo lleno NO ofrece un botón que no puede resolverlo")
    func fullQuotaOffersNoFalseRemedy() {
        // Su remedio no vive en Ajustes de Ámbar: son los cinco idiomas reservados de todo el
        // sistema, y ninguna pantalla de la app puede liberar uno. Un botón que lleva a
        // donde no se resuelve es peor que ninguno — el texto y la acción apuntaban a
        // sitios distintos.
        let controls = Self.content(.failed(.languageQuotaFull), failure: .languageQuotaFull).controls
        #expect(!controls.contains(.openAppSettings))
        #expect(!controls.contains(.openSystemSettings))
        #expect(controls.contains(.dismissFailure))
    }

    @Test("en reposo no se ofrece nada")
    func idleOffersNothing() {
        #expect(Self.content(.idle).controls.isEmpty)
    }

    // MARK: - Lo que se dice

    @Test("durante la cuenta el rótulo es la instrucción, también con el modelo ya cargado")
    func armingAlwaysAsksToHold() {
        // Con el modelo caliente `prepare()` cuesta 4-5 ms, así que `prepared: true` es el
        // caso NORMAL. Mostrar ahí «Preparado para dictar» sustituía lo único accionable
        // —mantén— por una frase que se lee como invitación a hablar, con el micrófono
        // todavía cerrado: quien empezara a hablar perdía las primeras sílabas.
        let expected = String(localized: "dictation.state.arming", bundle: .localized)
        #expect(Self.content(.arming(progress: 0.4, prepared: true)).title == expected)
        #expect(Self.content(.arming(progress: 0.4, prepared: false)).title == expected)
    }

    @Test("el fallo se cuenta con su causa, no con el genérico")
    func failureTitleCarriesTheCause() {
        for failure in DictationFailure.allCases {
            let title = Self.content(.failed(failure), failure: failure).title
            #expect(title == DictationController.message(for: failure), "genérico en \(failure)")
        }
        // Y las causas son distintas entre sí: si colapsaran, «con su causa» no significaría
        // nada. Fueron un genérico único durante dos rondas.
        let titles = Set(DictationFailure.allCases.map {
            Self.content(.failed($0), failure: $0).title
        })
        #expect(titles.count == DictationFailure.allCases.count)
    }

    @Test("una entrega recortada lo confiesa en el rótulo")
    func truncatedDeliveryConfesses() {
        let truncated = Transcript(text: "puede faltar", mode: .live, wasTruncated: true)
        let complete = Transcript(text: "completo", mode: .live)
        #expect(
            Self.content(.delivered(truncated)).title
                == String(localized: "dictation.state.truncated", bundle: .localized)
        )
        #expect(
            Self.content(.delivered(complete)).title
                == String(localized: "dictation.state.delivered", bundle: .localized)
        )
    }

    @Test("el símbolo de la cuenta no es el de micrófono silenciado")
    func armingSymbolIsNotMuted() {
        // `mic.slash` significa «silenciado» en el resto del sistema y se usa para botones de
        // silencio: junto a una fila con controles, se leía como desactivado.
        #expect(Self.content(.arming(progress: 0.2, prepared: false)).symbol != "mic.slash")
        // Y el de escucha sí es el lleno: es el que coincide con el indicador del sistema.
        #expect(Self.content(.listening).symbol == "mic.fill")
    }

    // MARK: - Lo que oye VoiceOver

    @Test("el texto en vivo viaja en la etiqueta, no en un hijo")
    func liveTextTravelsInTheLabel() {
        // VoiceOver locuta la etiqueta del elemento; un texto que solo está en un hijo no se
        // lee al recorrer.
        let content = Self.content(.listening, liveText: "hola mundo")
        #expect(content.accessibilityLabel.contains("hola mundo"))
        #expect(content.accessibilityLabel.contains(content.title))
    }

    @Test("el avance de la cuenta se expone como valor, y solo en la cuenta")
    func progressIsExposedOnlyWhileArming() {
        // El indicador visual va `accessibilityHidden` en sus dos representaciones, así que
        // sin esto el umbral no existe para quien no ve la pantalla: no hay forma de saber
        // cuánto queda para que se abra el micrófono, ni de decidir soltar.
        #expect(!Self.content(.arming(progress: 0.5, prepared: false)).accessibilityValue.isEmpty)
        #expect(Self.content(.listening).accessibilityValue.isEmpty)
        #expect(Self.content(.idle).accessibilityValue.isEmpty)
    }

    @Test("el avance se formatea con el locale, no a mano")
    func progressUsesFormatStyle() {
        // El espacio antes del % es convención es/fr, y en inglés, japonés, chino o coreano
        // se escribe pegado. Concatenar «%» a mano lo rompe en la mitad de los idiomas.
        let value = Self.content(.arming(progress: 0.5, prepared: false)).accessibilityValue
        #expect(value.contains("50"))
        #expect(value.contains("%"))
    }
}

/// La hipótesis tiene que **verse distinta** del texto ya firme, también en alto contraste.
///
/// Con el color como único canal, la distinción se perdía justo con «Aumentar contraste»:
/// ese ajuste sube el token de la hipótesis a opacidad plena —para eso está— y entonces los
/// dos textos se dibujan idénticos, 12,08:1 los dos. La única señal de «esto todavía puede
/// cambiar» desaparecía para quien había pedido ver mejor, y ninguna suite lo notaba porque
/// las dos ramas se medían por separado y las dos cumplían AA.
@Suite("La hipótesis se distingue del texto firme")
@MainActor
struct VolatileDistinctionTests {

    @Test("en contraste normal y en alto contraste, los estilos difieren")
    func volatileDiffersInBothModes() {
        for increaseContrast in [false, true] {
            let volatil = DictationBanner.transcriptStyle(
                isVolatile: true, increaseContrast: increaseContrast
            )
            let firme = DictationBanner.transcriptStyle(
                isVolatile: false, increaseContrast: increaseContrast
            )
            #expect(
                volatil != firme,
                "con increaseContrast=\(increaseContrast) la hipótesis se dibuja igual que el texto firme"
            )
        }
    }

    @Test("en alto contraste la distinción NO puede depender del color")
    func highContrastKeepsANonColourChannel() {
        // Aquí las dos opacidades coinciden a propósito: subir la hipótesis es lo correcto
        // para la legibilidad (R14: la estética no manda sobre la función). Lo que no puede
        // pasar es que ese acierto se lleve por delante la distinción, así que tiene que
        // quedar un canal que no sea el color.
        let volatil = DictationBanner.transcriptStyle(isVolatile: true, increaseContrast: true)
        let firme = DictationBanner.transcriptStyle(isVolatile: false, increaseContrast: true)
        #expect(volatil.opacity == firme.opacity, "cambió la premisa de este test")
        #expect(volatil.italic != firme.italic, "sin canal alternativo: son indistinguibles")
    }

    @Test("en contraste normal la hipótesis además se atenúa")
    func volatileIsDimmedInNormalContrast() {
        // El canal de color sigue siendo el primario cuando se puede permitir: atenuar es
        // lo que hace que la hipótesis se lea como provisional de un vistazo, sin tener
        // que fijarse en la inclinación de la letra. La cursiva es el respaldo para cuando
        // subir la opacidad es obligatorio, no el sustituto.
        let volatil = DictationBanner.transcriptStyle(isVolatile: true, increaseContrast: false)
        #expect(volatil.opacity < 1, "la hipótesis se dibuja tan firme como el texto cerrado")
        #expect(volatil.opacity > 0.8, "tan atenuada que dejaría de leerse: \(volatil.opacity)")
    }

    @Test("el texto firme se dibuja a opacidad plena")
    func settledTextIsFullyOpaque() {
        // Atenuar lo ya firme sería mentir en la dirección contraria: parecería que
        // todavía puede cambiar.
        #expect(DictationBanner.transcriptStyle(isVolatile: false, increaseContrast: false).opacity == 1)
        #expect(DictationBanner.transcriptStyle(isVolatile: false, increaseContrast: true).opacity == 1)
    }
}

/// El indicador de la cuenta del gesto tiene dos representaciones deliberadamente
/// distintas —§8.4 del diseño—, y no es cosmético: sin la escalera discreta, quien pidió
/// «Reducir movimiento» no vería venir el dictado, porque la única representación
/// alternativa está animada.
@Suite("El indicador de la cuenta respeta Reducir Movimiento")
// `ArmingIndicator` es una vista de SwiftUI y sus ayudantes estáticos están aislados al
// actor principal. Sin esto, las 18 llamadas de este suite salían con
// `[#ActorIsolatedCall]`: avisos que Swift 6 emite hoy y que en una versión futura del
// modo estricto pasan a ser errores.
@MainActor
struct ArmingIndicatorTests {

    @Test("Reducir Movimiento cambia la representación, no solo el ajuste")
    func reduceMotionSelectsSteps() {
        #expect(ArmingIndicator.representation(reduceMotion: true) == .steps)
        #expect(ArmingIndicator.representation(reduceMotion: false) == .bar)
    }

    @Test("los puntos se rellenan en el umbral que les toca")
    func stepsFillAtTheirThreshold() {
        // Con 5 puntos: el primero al 20%, el último al 100%.
        #expect(!ArmingIndicator.isStepFilled(0, progress: 0.0))
        #expect(ArmingIndicator.isStepFilled(0, progress: 0.2))
        #expect(!ArmingIndicator.isStepFilled(1, progress: 0.2))
        #expect(ArmingIndicator.isStepFilled(4, progress: 1.0), "el último punto no se rellena al completar")
        #expect(!ArmingIndicator.isStepFilled(4, progress: 0.99))
    }

    @Test("el margen absorbe el redondeo de la cuenta acumulada")
    func marginAbsorbsFloatingPointDrift() {
        // La cuenta llega como un cociente de duraciones (elapsed / threshold), no como
        // una fracción exacta: puede caer una micra por debajo del umbral del punto sin
        // que el gesto esté, en ningún sentido útil, incompleto. Sin el margen, ese punto
        // se quedaría vacío justo en el instante en que el gesto se confirma — la
        // información que la escalera existe para dar.
        let justShortOfTheThreshold = 1.0 / 5.0 - 0.0001
        #expect(ArmingIndicator.isStepFilled(0, progress: justShortOfTheThreshold))
        // Y el margen no es infinito: un progreso genuinamente insuficiente sigue vacío.
        #expect(!ArmingIndicator.isStepFilled(0, progress: 0.1))
    }
}
