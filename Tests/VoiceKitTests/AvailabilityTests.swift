import AVFoundation
import Foundation
import Testing

@testable import VoiceKit

/// F1 — qué se le ofrece al usuario según el entorno.
///
/// La regla que se prueba es que el dictado **nunca se ofrece como listo** si
/// falta algo, y que cuando se ofrece con la máquina justa se ofrece advirtiendo,
/// no en silencio. El orden de los motivos también se prueba: al usuario se le
/// dice el obstáculo que de verdad le bloquea, no el primero que encontramos.
@Suite("Disponibilidad del dictado")
struct AvailabilityTests {

    /// Entorno con todo en orden, para ir estropeando una cosa a la vez.
    static func ready(
        availability: ModelAvailability = .installed,
        permission: MicrophonePermission = .granted,
        hasInputDevice: Bool = true,
        capability: Capability = .comfortable
    ) -> DictationReadiness {
        DictationReadiness(
            availability: availability,
            permission: permission,
            hasInputDevice: hasInputDevice,
            capability: capability
        )
    }

    // MARK: - Cuándo no se puede

    @Test("un idioma no admitido no se puede activar, pase lo que pase")
    func unsupportedLocaleAlwaysBlocks() {
        // Incluso con permiso, micrófono y una máquina holgada.
        let readiness = Self.ready(availability: .unsupported)
        #expect(readiness.offer == .unavailable(.localeUnsupported))
    }

    @Test("sin entrada de audio no se puede activar")
    func noInputDeviceBlocks() {
        #expect(Self.ready(hasInputDevice: false).offer == .unavailable(.noMicrophone))
    }

    @Test("con el permiso denegado no se puede activar")
    func deniedPermissionBlocks() {
        #expect(Self.ready(permission: .denied).offer == .unavailable(.microphoneDenied))
    }

    /// Este test decía lo contrario —«el permiso sin decidir no bloquea: se pedirá al
    /// activar»— y consagraba un hueco real. Es cierto que activar la función pide el permiso,
    /// pero hay un estado en el que nadie activa nada: la app arranca con el dictado **ya
    /// encendido** en las preferencias y el permiso sin pedir, porque se encendió en otra
    /// copia, porque la app se movió, o porque alguien corrió `tccutil reset Microphone`. Ahí
    /// la oferta decía «listo», el gesto armaba, y el permiso saltaba a mitad de la primera
    /// sesión — con el agravante de que el remedio ofrecido, «Abrir Ajustes», lleva a una
    /// lista donde la app **no aparece**: macOS solo enumera las que ya lo han pedido.
    @Test("sin permiso decidido no se declara lista: hay que pedirlo")
    func notDeterminedPermissionAsksForIt() {
        #expect(Self.ready(permission: .notDetermined).offer == .needsMicrophonePermission)
    }

    /// Denegado y sin decidir no son lo mismo, y el remedio tampoco: uno manda a Ajustes del
    /// Sistema —macOS no vuelve a preguntar— y el otro se resuelve con un botón.
    @Test("denegado y sin decidir producen ofertas distintas")
    func deniedAndUndecidedDiffer() {
        #expect(Self.ready(permission: .denied).offer != Self.ready(permission: .notDetermined).offer)
    }

    /// El permiso va **antes** que el modelo: se resuelve con un clic y el modelo es una
    /// descarga, así que anunciar la descarga a quien además tiene el micrófono sin pedir le
    /// esconde el obstáculo inmediato.
    @Test("con el permiso sin pedir y el modelo por instalar, manda el permiso")
    func permissionBeatsModel() {
        let readiness = DictationReadiness(
            availability: .supported,
            permission: .notDetermined,
            hasInputDevice: true,
            capability: .unmeasured
        )
        #expect(readiness.offer == .needsMicrophonePermission)
    }

    @Test("el motivo que se muestra es el que de verdad bloquea")
    func reasonPrecedence() {
        // Todo mal a la vez: manda lo que no tiene arreglo desde la app.
        let everythingWrong = DictationReadiness(
            availability: .unsupported,
            permission: .denied,
            hasInputDevice: false,
            capability: .tight
        )
        #expect(everythingWrong.offer == .unavailable(.localeUnsupported))

        // Con el idioma bien, manda el hardware antes que el permiso: sin
        // micrófono, conceder el permiso no arregla nada.
        let noDevice = DictationReadiness(
            availability: .installed,
            permission: .denied,
            hasInputDevice: false,
            capability: .comfortable
        )
        #expect(noDevice.offer == .unavailable(.noMicrophone))
    }

    // MARK: - Modelo

    @Test("si el modelo no está instalado se dice antes de ofrecer nada")
    func supportedButNotInstalledNeedsModel() {
        #expect(Self.ready(availability: .supported).offer == .needsModel)
    }

    @Test("mientras se instala, el dictado no está listo")
    func downloadingIsNotReady() {
        #expect(Self.ready(availability: .downloading).offer == .installingModel)
    }

    // MARK: - Tono y modo

    @Test("con la máquina holgada se invita, y en vivo")
    func comfortableInvitesToLive() {
        #expect(
            Self.ready(capability: .comfortable).offer
                == .available(tone: .inviting, suggestedMode: .live)
        )
    }

    @Test("con la máquina justa se advierte, y en diferido")
    func tightWarnsAndSuggestsDeferred() {
        // La diferencia con el caso anterior no es que esté apagado —lo está en
        // los dos— sino el tono con el que se presenta.
        #expect(
            Self.ready(capability: .tight).offer
                == .available(tone: .warning, suggestedMode: .deferred)
        )
    }

    @Test("sin medir se propone el diferido, que funciona en cualquier máquina")
    func unmeasuredSuggestsDeferred() {
        #expect(Capability.unmeasured.suggestedMode == .deferred)
        #expect(
            Self.ready(capability: .unmeasured).offer
                == .available(tone: .inviting, suggestedMode: .deferred)
        )
    }

    // MARK: - Medición

    @Test("el factor de tiempo real se traduce con los umbrales")
    func realTimeFactorMapsToCapability() {
        let thresholds = CapabilityThresholds(comfortable: 0.5, realTime: 1.0)

        #expect(Capability(realTimeFactor: 0.2, thresholds: thresholds) == .comfortable)
        // El límite pertenece al lado holgado: 0,5 exacto cumple.
        #expect(Capability(realTimeFactor: 0.5, thresholds: thresholds) == .comfortable)
        #expect(Capability(realTimeFactor: 0.6, thresholds: thresholds) == .tight)
        #expect(Capability(realTimeFactor: 0.99, thresholds: thresholds) == .tight)
        // A partir de 1 el análisis no puede seguir al habla: no es «va justo», es que
        // el modo en vivo no sirve en esa máquina.
        #expect(Capability(realTimeFactor: 1.0, thresholds: thresholds) == .cannotFollowSpeech)
        #expect(Capability(realTimeFactor: 1.8, thresholds: thresholds) == .cannotFollowSpeech)
        #expect(Capability.cannotFollowSpeech.suggestedMode == .deferred)
    }

    @Test("una medida de otra máquina o de otro sistema no vale")
    func measurementIsScopedToMachineAndSystem() {
        let measurement = CapabilityMeasurement(
            realTimeFactor: 0.3,
            measuredAt: Date(timeIntervalSince1970: 0),
            machineIdentifier: "Mac16,10",
            systemVersion: "26.0"
        )

        #expect(measurement.isValid(machineIdentifier: "Mac16,10", systemVersion: "26.0"))
        // Otro Mac: hay que volver a medir.
        #expect(!measurement.isValid(machineIdentifier: "Mac14,2", systemVersion: "26.0"))
        // Misma máquina, sistema nuevo: el motor pudo cambiar de rendimiento.
        #expect(!measurement.isValid(machineIdentifier: "Mac16,10", systemVersion: "26.1"))
    }

    @Test("el umbral de tiempo real es 1,0 y ordena los dos umbrales")
    func thresholdsAreOrdered() {
        // La tautología anterior (`provisional == CapabilityThresholds()`) no decía
        // nada: `provisional` se define así. Lo que importa es que el 1,0 no es una
        // elección —es la definición de tiempo real— y que el umbral cómodo queda por
        // debajo, o la clasificación no tendría sentido.
        #expect(CapabilityThresholds.provisional.realTime == 1.0)
        #expect(CapabilityThresholds.provisional.comfortable < CapabilityThresholds.provisional.realTime)
    }
}

/// La traducción del permiso del sistema al del producto.
///
/// Vive en un test propio porque el estado real no se puede inyectar, y mientras la
/// traducción estuvo dentro del `switch` que consulta al sistema, tratar `restricted`
/// como **concedido** no rompía nada — medido con una mutación. Con eso, un equipo
/// gestionado por control parental o por una organización abriría el micrófono para
/// recibir silencio, sin fallo y sin explicación.
@Suite("Traducción del permiso de micrófono")
struct MicrophonePermissionMappingTests {

    @Test("concedido es concedido")
    func authorizedIsGranted() {
        #expect(MicrophoneAuthorization.permission(for: .authorized) == .granted)
    }

    @Test("sin decidir no es ni denegado ni concedido")
    func notDeterminedStaysUndecided() {
        // Importa que no colapse a `.denied`: es lo que distingue «hay que pedirlo» de
        // «ya se pidió y dijeron no», y de ahí depende que Ajustes ofrezca activar.
        #expect(MicrophoneAuthorization.permission(for: .notDetermined) == .notDetermined)
    }

    @Test("denegado y restringido son lo mismo para la app")
    func deniedAndRestrictedBothBlock() {
        #expect(MicrophoneAuthorization.permission(for: .denied) == .denied)
        // `restricted` es control parental o gestión del dispositivo: la app no puede
        // hacer nada, y tratarlo como concedido sería abrir el micrófono para nada.
        #expect(MicrophoneAuthorization.permission(for: .restricted) == .denied)
    }
}
