import Foundation
import AppCore
import SwiftUI
import Testing
import VoiceKit

@testable import Ambar

/// Las dos puertas del dictado que no exigen mantener una tecla.
///
/// Existe porque las dos —el botón de micrófono y ⌘D— se podían borrar del código y la
/// suite seguía en verde. Son el único camino para quien tiene temblor, o usa Slow Keys
/// o Sticky Keys, y su desaparición es exactamente la clase de defecto que tres rondas
/// de auditoría tuvieron que encontrar a mano.
@Suite("Puertas del dictado sin gesto")
struct EntryPointsTests {

    @Test("el botón de micrófono se ve salvo mientras se escucha")
    func microphoneButtonVisibility() {
        // Visible en reposo, y TAMBIÉN durante la cuenta: ocultarlo ahí hacía
        // desaparecer la puerta justo mientras el atajo estaba pulsado.
        #expect(DictationEntryPoints.showsMicrophoneButton(for: .idle))
        #expect(DictationEntryPoints.showsMicrophoneButton(for: .arming(progress: 0.5, prepared: false)))
        #expect(DictationEntryPoints.showsMicrophoneButton(for: .preparing))
        #expect(DictationEntryPoints.showsMicrophoneButton(for: .failed(.noSpeechDetected)))
        // Escuchando manda el control de parar de la banda.
        #expect(!DictationEntryPoints.showsMicrophoneButton(for: .listening))
    }

    @Test("⌘D arranca, para o descarta según el estado")
    func commandDToggles() {
        #expect(DictationEntryPoints.commandDAction(for: .idle) == .start)
        #expect(DictationEntryPoints.commandDAction(for: .failed(.engineFailed)) == .start)
        #expect(
            DictationEntryPoints.commandDAction(
                for: .delivered(Transcript(text: "x", mode: .live))
            ) == .start
        )
        #expect(DictationEntryPoints.commandDAction(for: .listening) == .stop)

        // La rama que faltaba: en los estados donde no se puede arrancar ni parar, ⌘D
        // DESCARTA. Antes no hacía nada en silencio, y son justo los estados en los que
        // el usuario quiere salirse.
        #expect(DictationEntryPoints.commandDAction(for: .preparing) == .discard)
        #expect(DictationEntryPoints.commandDAction(for: .finalizing) == .discard)
        #expect(
            DictationEntryPoints.commandDAction(for: .arming(progress: 0.5, prepared: false)) == .discard
        )
    }

    /// El botón de micrófono no puede estar visible y ser inerte.
    ///
    /// Se pintaba en `.preparing` y `.finalizing`, donde `startWithoutGesture` sale por
    /// `default: return`: un control habilitado que no responde ni informa, justo en la
    /// puerta de entrada de quien no puede mantener una tecla.
    @Test("el botón de micrófono siempre hace algo cuando está visible")
    func visibleMicrophoneButtonAlwaysActs() {
        for state in [
            DictationSessionState.idle,
            .arming(progress: 0.5, prepared: false),
            .preparing,
            .finalizing,
            .delivered(Transcript(text: "x", mode: .live)),
            .failed(.noSpeechDetected),
            .listening,
        ] {
            guard DictationEntryPoints.showsMicrophoneButton(for: state) else { continue }
            // Su acción es la misma que la de ⌘D, así que nunca es un no-op.
            let action = DictationEntryPoints.commandDAction(for: state)
            #expect(action == .start || action == .discard, "\(state) → \(action)")
        }
    }
}

/// La ruta por teclado a los botones de remedio.
///
/// El panel declara **un único elemento enfocable** —el campo de búsqueda— y su
/// monitor se queda con los `keyDown`, así que el tabulador no llega a los botones del
/// banner. Sin este atajo, quien no usa ratón veía el fallo y no tenía cómo arreglarlo.
@Suite("Atajo a los ajustes que resuelven el fallo")
struct SettingsShortcutTests {

    @Test("con el permiso denegado, ⌘, abre el panel del sistema")
    func permissionFailureOpensSystemSettings() {
        #expect(
            DictationEntryPoints.settingsShortcutTarget(
                state: .failed(.permissionDenied),
                failure: .permissionDenied
            ) == .systemMicrophone
        )
    }

    @Test("con el modelo o el cupo, ⌘, abre los ajustes de Ámbar")
    func modelFailureOpensAppSettings() {
        // Son los dos fallos cuyo remedio vive en Ajustes de la app: instalar el modelo
        // y liberar un idioma del cupo.
        for failure in [DictationFailure.modelUnavailable, .languageQuotaFull] {
            #expect(
                DictationEntryPoints.settingsShortcutTarget(
                    state: .failed(failure),
                    failure: failure
                ) == .appSettings
            )
        }
    }

    @Test("sin fallo en pantalla, ⌘, hace lo que hace en cualquier app")
    func withoutFailureOpensAppSettings() {
        #expect(
            DictationEntryPoints.settingsShortcutTarget(state: .idle, failure: nil) == .appSettings
        )
        // Y con el dictado apagado —sin controlador— también: `nil` no puede dejar el
        // atajo muerto, porque entonces ⌘, no haría nada para la mayoría de la gente.
        #expect(
            DictationEntryPoints.settingsShortcutTarget(state: nil, failure: nil) == .appSettings
        )
    }

    @Test("un fallo viejo no secuestra el atajo cuando ya no se muestra")
    func staleFailureDoesNotHijackTheShortcut() {
        // `lastFailure` sobrevive al estado: si solo se mirara el motivo, ⌘, seguiría
        // abriendo el panel del sistema mucho después de que el aviso desapareciera.
        #expect(
            DictationEntryPoints.settingsShortcutTarget(
                state: .idle,
                failure: .permissionDenied
            ) == .appSettings
        )
    }
}

/// Las dos puertas de la interfaz del dictado, como predicados afirmables.
///
/// Existen porque los `if` de una vista SwiftUI no se pueden ejercitar en un test de
/// unidad, y con la decisión escrita dentro del cuerpo de la vista **la elección de
/// predicado no estaba cubierta**: cambiar el gate de la banda de `deservesDisplay` a
/// `isActive` —que parece equivalente— no rompía nada, y es exactamente el bloqueante de
/// la ronda 1: con `isActive` los fallos no se pintan.
@Suite("Las puertas de la interfaz del dictado")
struct DictationSurfaceGateTests {

    @Test("un fallo se pinta, aunque la sesión ya no esté activa")
    func failureIsShown() {
        // `isActive` es falso para `.failed`. Esa es toda la diferencia, y es la que
        // hacía que el dictado fallara en silencio.
        #expect(DictationEntryPoints.showsBanner(for: .failed(.noSpeechDetected)))
        #expect(DictationEntryPoints.showsBanner(for: .failed(.permissionDenied)))
    }

    @Test("una entrega recortada se pinta para poder confesarla")
    func truncatedDeliveryIsShown() {
        let truncated = Transcript(text: "puede faltar", mode: .live, wasTruncated: true)
        #expect(DictationEntryPoints.showsBanner(for: .delivered(truncated)))
        // Y una entrega completa no: no hay nada que decir.
        let complete = Transcript(text: "completo", mode: .live)
        #expect(!DictationEntryPoints.showsBanner(for: .delivered(complete)))
    }

    @Test("durante la cuenta se pinta solo al pasar el umbral")
    func armingIsShownOnlyPastTheThreshold() {
        // Por debajo no: si no, cada apertura del historial por atajo —la acción más
        // frecuente de la app— parpadearía una banda.
        #expect(!DictationEntryPoints.showsBanner(for: .arming(progress: 0.1, prepared: false)))
        #expect(DictationEntryPoints.showsBanner(for: .arming(progress: 0.9, prepared: false)))
    }

    @Test("el control de parar se ofrece siempre que el micrófono esté abierto")
    func stopIsOfferedWheneverTheMicIsOpen() {
        #expect(DictationEntryPoints.showsStopControl(for: .listening))
        // Y en ningún otro estado: en `.finalizing` el micrófono ya está cerrado, y
        // ofrecer «parar» ahí sugiere que sigue grabando.
        #expect(!DictationEntryPoints.showsStopControl(for: .finalizing))
        #expect(!DictationEntryPoints.showsStopControl(for: .preparing))
        #expect(!DictationEntryPoints.showsStopControl(for: .idle))
    }
}

/// La transición de la banda del dictado.
///
/// §8.4 promete «transición animada de uso principal a *escuchando*» frente a
/// «progresión por pasos discretos, **sin movimiento**» con Reducir movimiento. Estuvo tres
/// rondas sin implementarse mientras el documento afirmaba que sí: la banda aparecía de
/// golpe, y con ella el salto de maquetación de la lista, idéntico con Reducir movimiento
/// activado — o sea, para quien se le prometió lo contrario.
@Suite("Transición de la banda del dictado")
struct DictationBannerTransitionTests {

    @Test("con Reducir movimiento no hay ninguna animación")
    func reduceMotionMeansNoMotion() {
        // `.identity` es literalmente «sin transición». No un desplazamiento más corto,
        // ni un desvanecido: quien pide reducir movimiento no pide menos movimiento.
        #expect(DictationBannerTransition.kind(reduceMotion: true) == .none)
    }

    @Test("sin esa preferencia, la banda entra con movimiento")
    func defaultTransitionMoves() {
        #expect(DictationBannerTransition.kind(reduceMotion: false) == .growFromTop)
    }

    @Test("la transición dura menos que el umbral del gesto")
    func transitionIsShorterThanTheThreshold() {
        // Si duraran lo mismo, la animación terminaría justo cuando el micrófono se abre
        // y no habría dado ninguna ventana para soltar. El umbral es un valor propio que
        // se ajustará observando a gente real; la animación no puede secuestrarlo.
        #expect(DictationBannerTransition.duration < HoldGesture.provisionalThreshold)
    }
}

/// La identidad de animación no puede incluir el avance.
///
/// La animación de la banda se dispara con `value:`. Con el estado entero, ese valor cambiaba
/// en **cada tic de 40 ms** —`progress` vive dentro de `.arming`—, así que el `easeOut` se
/// aplicaba también al ancho de la cápsula del indicador y la representación del umbral iba
/// hasta 220 ms por detrás del umbral que representa. Con «Reducir movimiento» no ocurría,
/// porque ahí no hay animación: el camino accesible era el fiel y el de por defecto el
/// engañoso, al revés de lo que pretende §8.4.
@Suite("Identidad de animación del dictado")
struct AnimationIdentityTests {

    @Test("dentro de un tramo, el avance no cambia la identidad")
    func progressDoesNotChangeIdentityWithinASegment() {
        // Los tics de 40 ms no pueden reabrir la transacción: si lo hicieran, el `easeOut`
        // se aplicaría también al ancho de la cápsula y la representación del umbral iría
        // por detrás del umbral que representa.
        let a = DictationSessionState.arming(progress: 0.4, prepared: false)
        let b = DictationSessionState.arming(progress: 0.9, prepared: true)
        #expect(a.animationIdentity == b.animationIdentity)
        #expect(a != b, "si fueran el mismo estado, esto no probaría nada")

        let veryEarly = DictationSessionState.arming(progress: 0.0, prepared: false)
        let stillEarly = DictationSessionState.arming(progress: 0.2, prepared: false)
        #expect(veryEarly.animationIdentity == stillEarly.animationIdentity)
    }

    /// Y el caso que el arreglo anterior rompió: **la identidad tiene que cambiar cuando la
    /// banda aparece**, o la inserción ocurre sin animación.
    @Test("cruzar el umbral de aparición cambia la identidad")
    func crossingTheDisplayThresholdChangesIdentity() {
        let hidden = DictationSessionState.arming(progress: 0.2, prepared: false)
        let visible = DictationSessionState.arming(progress: 0.4, prepared: false)

        // `.animation(_:value:)` solo abre transacción animada cuando el valor cambia. Con
        // una sola identidad para toda la cuenta, la banda se insertaba en un frame —el
        // corte seco que §8.4 dice evitar— mientras la salida sí se animaba.
        #expect(hidden.animationIdentity != visible.animationIdentity)
        // Y que de verdad son los dos lados del umbral: si `deservesDisplay` y la identidad
        // usaran criterios distintos, esto no significaría nada.
        #expect(!hidden.deservesDisplay)
        #expect(visible.deservesDisplay)
    }

    @Test("cada estado sí tiene su propia identidad")
    func statesAreDistinguishable() {
        let identities = [
            DictationSessionState.idle,
            .arming(progress: 0.5, prepared: false),
            .preparing,
            .listening,
            .finalizing,
            .delivered(Transcript(text: "x", mode: .live)),
            .failed(.engineFailed),
        ].map(\.animationIdentity)

        // Sin esto la transición no se dispararía al entrar o salir de la banda, que es
        // para lo único que existe la animación.
        #expect(Set(identities).count == identities.count)
    }
}

/// La duración declarada tiene que **gobernar** la animación.
///
/// `duration` llevaba el razonamiento load-bearing —«más corta que el umbral del gesto: si
/// durara lo mismo, la animación acabaría justo cuando el micrófono se abre y no habría
/// dado ninguna ventana para soltar»— y su único consumidor era un test. La animación real
/// usaba un literal aparte, así que subirlo a 0,9 s dejaba el test verde y la representación
/// terminando después del hecho que representa.
@Suite("La duración declarada gobierna la animación")
struct BannerDurationTests {

    @Test("los segundos que usa SwiftUI salen de la duración declarada")
    func secondsDeriveFromDuration() {
        #expect(abs(DictationBannerTransition.durationInSeconds - 0.220) < 0.0005)
    }

    @Test("y siguen por debajo del umbral del gesto")
    func stillShorterThanTheThreshold() {
        // El invariante que justifica el valor: la ventana para soltar tiene que existir.
        let threshold = Double(HoldGesture.provisionalThreshold.components.seconds)
            + Double(HoldGesture.provisionalThreshold.components.attoseconds) / 1e18
        #expect(DictationBannerTransition.durationInSeconds < threshold)
    }
}
