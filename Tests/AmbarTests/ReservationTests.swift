import Foundation
import Testing
import VoiceKit

@testable import Ambar

/// La reserva de idioma es un recurso del **sistema**: cinco ranuras para toda la
/// máquina, compartidas con cualquier otra app que dicte. Consultar el estado del
/// modelo exige reservar —sin la reserva, el framework responde `supported` para un
/// modelo que ya está instalado—, y de ahí sale la trampa: abrir Ajustes con el
/// dictado apagado cogía una ranura para siempre.
///
/// Eso contradice de plano lo que §4 del diseño promete —«apagado significa: no se
/// instancia nada»— y es invisible desde la app: no hay síntoma hasta que otra
/// aplicación se queda sin poder reservar.
@Suite("Reserva de idioma", .serialized)
@MainActor
struct ReservationTests {

    /// Catálogo con inventario propio. Existe porque el de verdad toca
    /// `AssetInventory`, que es estado global del sistema: un test que lo usara
    /// dejaría la máquina distinta de como la encontró, y no podría comprobar una
    /// fuga sin depender de lo que hicieran los demás tests.
    final class SpyCatalog: ModelCatalog, @unchecked Sendable {
        private let lock = NSLock()
        private var held: Set<String> = []
        private(set) var reserveCalls = 0
        private(set) var releaseCalls = 0
        /// Qué se responde cuando el idioma está reservado. Sustituible para poder
        /// montar la oferta del primer arranque (`.supported` = falta instalarlo).
        private let whenHeld: ModelAvailability

        init(availability: ModelAvailability = .installed) {
            self.whenHeld = availability
        }

        /// Idiomas reservados ahora mismo. Es lo que se interroga al final.
        var reservedIdentifiers: Set<String> {
            lock.withLock { held }
        }

        /// Simula que la ranura ya estaba cogida antes de entrar.
        ///
        /// Reserva **todas** las variantes que este doble puede resolver: como la resolución
        /// no es determinista —igual que la del framework—, apuntar a una sola dejaría el
        /// caso al azar, y un test que depende del azar no prueba nada.
        func preReserveAll() {
            lock.withLock { variants.forEach { held.insert($0) } }
        }

        /// Devuelve una **variante distinta en cada llamada**, como el framework real cuando
        /// el idioma pedido no casa exacto entre los admitidos. Con la identidad —que es lo
        /// que este doble hacía— la fuga que esto destapa era invisible.
        private var resolutions = 0
        let variants = ["de_AT", "de_CH", "de_DE"]
        func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
            defer { resolutions += 1 }
            return Locale(identifier: variants[resolutions % variants.count])
        }

        func availability(forLocale locale: Locale) async -> ModelAvailability {
            // Reproduce el comportamiento medido: instalado solo mientras se sostiene
            // la reserva. Es lo que obliga a reservar para consultar.
            lock.withLock { held.contains(locale.identifier) ? whenHeld : .supported }
        }

        /// `true` si la próxima llamada a `installModel` debe fallar, para probar el
        /// camino de error sin tocar la red.
        private var shouldFailNextInstall = false
        func failNextInstall() { lock.withLock { shouldFailNextInstall = true } }

        struct InstallFailure: Error {}

        /// Con qué idioma se pidió instalar. Es lo único que puede delatar que quien
        /// llama no resolvió antes: si llega `de` en vez de una de las variantes, el
        /// catálogo tendría que resolver por su cuenta ahí dentro y podría descargar una
        /// distinta de la que se comprueba después.
        private(set) var installedLocales: [String] = []

        func installModel(
            forLocale locale: Locale,
            onProgress: @Sendable @escaping (Double) -> Void
        ) async throws {
            lock.withLock { installedLocales.append(locale.identifier) }
            if lock.withLock({ shouldFailNextInstall }) { throw InstallFailure() }
        }

        func installationSize(forLocale locale: Locale) async -> Int64? { nil }

        func reserve(locale: Locale) async throws -> Bool {
            lock.withLock {
                reserveCalls += 1
                // Igual que el real: `false` si ya estaba reservado.
                return held.insert(locale.identifier).inserted
            }
        }

        func release(locale: Locale) async {
            lock.withLock {
                releaseCalls += 1
                held.remove(locale.identifier)
            }
        }

        func reservation() async -> (maximum: Int, reserved: [Locale]) {
            lock.withLock { (5, held.map { Locale(identifier: $0) }) }
        }

        private(set) var retentionEnded = 0
        func endModelRetention() async {
            lock.withLock { retentionEnded += 1 }
        }
    }

    static func model(dictationEnabled: Bool, catalog: SpyCatalog) -> AppModel {
        let settings = Settings(defaults: UserDefaults(suiteName: "ambar.tests.reservation.\(UUID().uuidString)")!)
        settings.isDictationEnabled = dictationEnabled
        let model = AppModel(settings: settings)
        model.catalogProvider = { _ in catalog }
        // Fixed, never read from the machine: a test run next to a live Ámbar must not
        // change which branch of the launch sweep it exercises.
        model.anotherInstanceIsRunning = { false }
        return model
    }

    @Test("consultar la oferta con el dictado apagado no se queda con la ranura")
    func offerWithDictationOffReleasesReservation() async {
        let catalog = SpyCatalog()
        let model = Self.model(dictationEnabled: false, catalog: catalog)

        await model.refreshDictationOffer(permission: .granted)

        // Reservó —si no, la oferta habría mentido diciendo que falta instalar—
        #expect(catalog.reserveCalls == 1)
        // …y lo soltó al salir.
        #expect(catalog.releaseCalls == 1)
        #expect(catalog.reservedIdentifiers.isEmpty)
    }

    @Test("y la consulta sigue viendo el modelo instalado, que es para lo que reserva")
    func offerStillSeesInstalledModel() async {
        let catalog = SpyCatalog()
        let model = Self.model(dictationEnabled: false, catalog: catalog)

        await model.refreshDictationOffer(permission: .granted)

        // El orden importa: si se soltara antes de consultar, la oferta diría
        // `.needsModel` y Ajustes ofrecería descargar lo que ya está en el disco.
        #expect(model.dictationOffer != .needsModel)
        #expect(model.dictationOffer != nil)
    }

    @Test("con el dictado encendido la reserva se mantiene: es uso legítimo")
    func offerWithDictationOnKeepsReservation() async {
        let catalog = SpyCatalog()
        let model = Self.model(dictationEnabled: true, catalog: catalog)

        await model.refreshDictationOffer(permission: .granted)

        #expect(catalog.releaseCalls == 0)
        #expect(!catalog.reservedIdentifiers.isEmpty, "no reservó nada")
    }

    /// **Las reservas sobreviven al proceso.** Medido en macOS 26.0: un proceso reserva
    /// `fr_FR` y termina; el siguiente proceso de la misma app lo encuentra reservado.
    ///
    /// Este test decía lo contrario —que una reserva preexistente es «de otro» y no se
    /// toca— y esa creencia es la que dejó el dictado inservible: lo fugado no se iba al
    /// cerrar Ámbar, se quedaba semanas, y a las cinco ranuras el dictado dejaba de
    /// arrancar. Al arrancar no hay ninguna sesión viva, así que lo que hay puesto es
    /// nuestro de ayer y se devuelve.
    @Test("al arrancar se devuelven las ranuras que quedaron de ejecuciones anteriores")
    func strayReservationsAreReclaimedOnLaunch() async {
        let catalog = SpyCatalog()
        catalog.preReserveAll()
        let model = Self.model(dictationEnabled: false, catalog: catalog)

        await model.refreshDictationOffer(permission: .granted)

        #expect(
            catalog.reservedIdentifiers.isEmpty,
            "quedaron ranuras de una ejecución anterior: \(catalog.reservedIdentifiers)"
        )
    }

    /// The reservation is per app, not per process: an instance sweeping at launch while
    /// another Ámbar runs takes the language from under it, and that one then answers
    /// "Falta el modelo de voz" with the model installed. Measured on 2026-10-01.
    @Test("the launch sweep leaves the reservations alone while another Ámbar is running")
    func launchSweepSparesAnotherRunningInstance() async {
        let catalog = SpyCatalog()
        catalog.preReserveAll()
        let model = Self.model(dictationEnabled: true, catalog: catalog)
        model.anotherInstanceIsRunning = { true }

        await model.refreshDictationOffer(permission: .granted)

        #expect(catalog.releaseCalls == 0, "released the running instance's language")
        #expect(catalog.reservedIdentifiers == Set(catalog.variants))
    }

    /// Y lo que el test anterior sí protegía de verdad, conservado: **después** del
    /// arranque puede haber una sesión de dictado en curso, y quitarle el idioma a mitad
    /// es peor que la fuga que repara. El barrido es una sola vez.
    @Test("una reserva que aparece después del arranque no se toca")
    func reservationsAppearingAfterLaunchAreLeftAlone() async {
        let catalog = SpyCatalog()
        let model = Self.model(dictationEnabled: true, catalog: catalog)

        // Primer refresco: el barrido ya ha corrido.
        await model.refreshDictationOffer(permission: .granted)

        // Ahora entra en escena alguien más — una sesión de dictado que reserva su idioma.
        catalog.preReserveAll()
        #expect(catalog.reservedIdentifiers.count == catalog.variants.count)

        await model.refreshDictationOffer(permission: .granted)

        // El modelo suelta como mucho LA SUYA —la que apuntó en el refresco anterior—, y
        // deja en pie las demás. Si volviera a barrer, quedaría una sola.
        #expect(
            catalog.reservedIdentifiers.count >= catalog.variants.count - 1,
            "barrió de nuevo y le quitó la ranura a una sesión en curso: \(catalog.reservedIdentifiers)"
        )
    }

    @Test("apagar el dictado devuelve la ranura y el modelo residente")
    func disablingReleasesEverything() async throws {
        let catalog = SpyCatalog()
        let model = Self.model(dictationEnabled: true, catalog: catalog)

        // Con el dictado encendido, consultar la oferta se queda la reserva: es uso
        // legítimo mientras la función esté activa.
        await model.refreshDictationOffer(permission: .granted)
        // Lo reservado es el idioma **resuelto**, que no tiene por qué ser el pedido.
        #expect(!catalog.reservedIdentifiers.isEmpty, "no reservó nada")

        model.disableDictation()
        // El `Task` de la liberación no se puede esperar desde fuera; se le da margen.
        try? await Task.sleep(for: .milliseconds(150))

        #expect(
            catalog.reservedIdentifiers.isEmpty,
            "apagar dejó cogida una de las cinco ranuras del sistema: \(catalog.reservedIdentifiers)"
        )
        #expect(catalog.retentionEnded >= 1, "no se soltó el modelo residente")
        #expect(model.dictationOffer == nil, "la oferta siguió afirmando algo tras apagar")
    }

    @Test("abrir Ajustes muchas veces no acumula reservas")
    func repeatedRefreshesDoNotAccumulate() async {
        let catalog = SpyCatalog()
        let model = Self.model(dictationEnabled: false, catalog: catalog)

        for _ in 0..<5 {
            await model.refreshDictationOffer(permission: .granted)
        }

        #expect(catalog.reserveCalls == 5)
        #expect(catalog.releaseCalls == 5)
        #expect(catalog.reservedIdentifiers.isEmpty)
    }

    /// El agujero por el que se coló la fuga que dejó el dictado inservible.
    ///
    /// Había un test de acumulación, pero solo con el dictado **apagado** — el camino
    /// que sí soltaba. Con el dictado encendido la reserva se conserva a propósito, y
    /// nadie comprobó qué pasaba al conservarla cinco veces seguidas para idiomas
    /// distintos: la app recordaba UNA, cada refresco pisaba el recuerdo, y la anterior
    /// se quedaba sin dueño hasta que el proceso muriera.
    ///
    /// Que el doble resuelva una variante distinta en cada llamada no es un capricho:
    /// es lo que hace el framework real sin coincidencia exacta, y es la vía por la que
    /// esto le ocurre a alguien que solo tiene un idioma configurado.
    @Test("con el dictado encendido, refrescar muchas veces tampoco acumula ranuras")
    func repeatedRefreshesWithDictationOnDoNotAccumulate() async {
        let catalog = SpyCatalog()
        let model = Self.model(dictationEnabled: true, catalog: catalog)

        for _ in 0..<5 {
            await model.refreshDictationOffer(permission: .granted)
        }

        // Una, la del idioma vigente. Ni cero —reservar es lo que hace que la oferta
        // no mienta— ni una por refresco.
        #expect(
            catalog.reservedIdentifiers.count == 1,
            "quedaron \(catalog.reservedIdentifiers.count) ranuras cogidas: \(catalog.reservedIdentifiers)"
        )
    }

    /// La consecuencia medible: pasar del cupo es lo que produce «no caben más idiomas»
    /// en la cara de alguien que no ha configurado más que uno.
    @Test("refrescar nunca deja pasar del cupo del sistema")
    func refreshingNeverExceedsTheSystemQuota() async {
        let catalog = SpyCatalog()
        let model = Self.model(dictationEnabled: true, catalog: catalog)
        let (maximum, _) = await catalog.reservation()

        for _ in 0..<(maximum * 2) {
            await model.refreshDictationOffer(permission: .granted)
        }

        #expect(catalog.reservedIdentifiers.count <= maximum)
    }
}

/// El modo con el que la función se estrena.
///
/// §6.1: sin ninguna medida de la máquina, el estreno **no** puede ser en vivo. La
/// decisión estaba escrita dentro de `enableDictation`, que pasa por el diálogo del
/// sistema y por tanto no se puede recorrer en un test: sustituirla por `break` no rompía
/// nada, y lo que se perdía era justo esa protección.
@Suite("El modo con el que se estrena el dictado")
@MainActor
struct OfferedModeTests {

    static func model(catalog: ReservationTests.SpyCatalog) -> AppModel {
        let defaults = UserDefaults(suiteName: "ambar.tests.mode.\(UUID().uuidString)")!
        // NO se toca `dictationMode` a mano: su setter marca «el usuario ya eligió», y
        // entonces ninguna sugerencia se aplica —que es el comportamiento correcto—. Se
        // parte del valor por defecto, que es el modo en vivo (§1 de la decisión de
        // producto), y es justo el que no debe sobrevivir a una oferta sin medir.
        let settings = Settings(defaults: defaults)
        let model = AppModel(settings: settings)
        model.catalogProvider = { _ in catalog }
        return model
    }

    @Test("con el modelo aún sin instalar, el estreno es en diferido")
    func needsModelStartsDeferred() async {
        // La oferta del primer arranque es `.needsModel`, y es exactamente el caso que se
        // escapaba: mirando solo `.available`, no se aplicaba nada y la función se
        // estrenaba en vivo.
        let catalog = ReservationTests.SpyCatalog(availability: .supported)
        let model = Self.model(catalog: catalog)

        await model.refreshDictationOffer(permission: .granted)
        model.applyOfferedMode()

        #expect(model.dictationOffer == .needsModel)
        #expect(model.settings.dictationMode == .deferred, "se estrenó en vivo sin medir nada")
    }

    @Test("sin oferta comprobada no se toca el modo")
    func unknownOfferChangesNothing() {
        let model = Self.model(catalog: ReservationTests.SpyCatalog())
        let before = model.settings.dictationMode
        model.applyOfferedMode()
        // `nil` es «todavía no se ha comprobado». Aplicar una recomendación que no existe
        // sería inventarse una medida.
        #expect(model.settings.dictationMode == before)
    }

    @Test("si el usuario ya eligió, la recomendación no le cambia el modo")
    func userChoiceWins() {
        let model = Self.model(catalog: ReservationTests.SpyCatalog())
        // El setter marca la elección: a partir de ahí, ninguna sugerencia manda.
        model.settings.dictationMode = .live
        model.applyOfferedMode()
        #expect(model.settings.dictationMode == .live)
    }
}

/// La medida de capacidad, de punta a punta: se guarda, caduca cuando debe, y **llega a
/// la oferta**.
///
/// Es la cadena que faltaba. `OfferTone.warning`, `Capability.tight`,
/// `CapabilityThresholds` y `CapabilityMeasurement` estaban escritos y probados en
/// aislamiento, y la oferta se construía con `capability: .unmeasured` fijo: ninguno podía
/// ocurrir en producción. La decisión del primer día —si la máquina no da, se recomienda
/// no activarlo— no tenía ninguna vía hasta el usuario.
@Suite("La medida de capacidad llega a la oferta")
@MainActor
struct CapabilityWiringTests {

    static func settings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "ambar.tests.capability.\(UUID().uuidString)")!)
    }

    static func measurement(_ factor: Double) -> CapabilityMeasurement {
        CapabilityMeasurement(
            realTimeFactor: factor,
            measuredAt: Date(timeIntervalSince1970: 1_000_000),
            machineIdentifier: CapabilityProbe.machineIdentifier(),
            systemVersion: CapabilityProbe.systemVersion()
        )
    }

    @Test("sin medir, la capacidad es «sin medir»")
    func withoutMeasurementCapabilityIsUnmeasured() {
        #expect(Self.settings().capability == .unmeasured)
    }

    @Test("una medida holgada se guarda y se lee")
    func comfortableMeasurementRoundTrips() {
        let settings = Self.settings()
        settings.capabilityMeasurement = Self.measurement(0.2)
        #expect(settings.capability == .comfortable)
    }

    @Test("una medida apretada se traduce a «va justa»")
    func tightMeasurementIsTight() {
        let settings = Self.settings()
        settings.capabilityMeasurement = Self.measurement(0.8)
        #expect(settings.capability == .tight)
    }

    @Test("una medida de otra máquina no se usa")
    func measurementFromAnotherMachineIsIgnored() {
        let settings = Self.settings()
        settings.capabilityMeasurement = CapabilityMeasurement(
            realTimeFactor: 0.2,
            measuredAt: Date(timeIntervalSince1970: 1_000_000),
            machineIdentifier: "Mac1,1",
            systemVersion: CapabilityProbe.systemVersion()
        )
        // Viajó en una copia de seguridad desde un Mac potente: usarla recomendaría el
        // modo en vivo en una máquina que no lo aguanta.
        #expect(settings.capability == .unmeasured)
    }

    @Test("con la máquina justa, la oferta ADVIERTE y propone el modo diferido")
    func tightMachineWarnsInTheOffer() async {
        let catalog = ReservationTests.SpyCatalog()
        let settings = Self.settings()
        settings.isDictationEnabled = true
        settings.capabilityMeasurement = Self.measurement(0.8)
        let model = AppModel(settings: settings)
        model.catalogProvider = { _ in catalog }

        await model.refreshDictationOffer(permission: .granted)

        // Este es el valor que no podía ocurrir. Y con él, la nota de Ajustes que lo
        // pinta (`DictationNote.tight`) y la cadena traducida a diez idiomas dejan de ser
        // inalcanzables.
        #expect(model.dictationOffer == .available(tone: .warning, suggestedMode: .deferred))
        #expect(DictationNote.resolve(for: model.dictationOffer) == .tight)
    }

    @Test("con la máquina holgada, la oferta invita al modo en vivo")
    func comfortableMachineInvitesToLive() async {
        let catalog = ReservationTests.SpyCatalog()
        let settings = Self.settings()
        settings.isDictationEnabled = true
        settings.capabilityMeasurement = Self.measurement(0.2)
        let model = AppModel(settings: settings)
        model.catalogProvider = { _ in catalog }

        await model.refreshDictationOffer(permission: .granted)

        #expect(model.dictationOffer == .available(tone: .inviting, suggestedMode: .live))
        #expect(DictationNote.resolve(for: model.dictationOffer) == .none)
    }

    @Test("una máquina que no puede seguir al habla no se presenta invitando")
    func machineThatCannotFollowSpeechWarns() async {
        let catalog = ReservationTests.SpyCatalog()
        let settings = Self.settings()
        settings.isDictationEnabled = true
        // Factor por encima de 1: el análisis va más lento que el habla.
        settings.capabilityMeasurement = Self.measurement(1.4)
        let model = AppModel(settings: settings)
        model.catalogProvider = { _ in catalog }

        await model.refreshDictationOffer(permission: .granted)

        #expect(settings.capability == .cannotFollowSpeech)
        // El caso que estaba mal por defecto: `cannotFollowSpeech` producía tono
        // `.inviting`, o sea que la máquina cuyo propio doc-comment dice «el modo en vivo
        // no es una opción» se ofrecía invitando, con «en vivo» seleccionable.
        #expect(model.dictationOffer == .available(tone: .warning, suggestedMode: .deferred))
    }
}

/// El predicado que decide si el gesto puede armar.
///
/// Su consumidor está probado —`isReady()` en `shortcutPressed`—, pero el predicado que lo
/// alimenta no lo estaba: `dictationCanRun` → `return true` dejaba la suite en verde, y con
/// eso vuelve el bloqueante de la ronda 9 entero (banda roja en cada apertura del historial
/// cuando falta el modelo).
@Suite("Cuándo puede funcionar el dictado")
@MainActor
struct DictationCanRunTests {

    static func model(catalog: ReservationTests.SpyCatalog) -> AppModel {
        let defaults = UserDefaults(suiteName: "ambar.tests.canrun.\(UUID().uuidString)")!
        let model = AppModel(settings: Settings(defaults: defaults))
        model.catalogProvider = { _ in catalog }
        return model
    }

    @Test("sin comprobar nada todavía, no")
    func unknownOfferCannotRun() {
        // `nil` es «aún no se ha mirado». El gesto es el camino que nadie pidió, así que
        // ante la duda no arma: equivocarse por el otro lado pinta un error no provocado.
        #expect(!Self.model(catalog: ReservationTests.SpyCatalog()).dictationCanRun)
    }

    @Test("con el modelo sin instalar, no")
    func needsModelCannotRun() async {
        let model = Self.model(catalog: ReservationTests.SpyCatalog(availability: .supported))
        await model.refreshDictationOffer(permission: .granted)
        #expect(model.dictationOffer == .needsModel)
        #expect(!model.dictationCanRun, "armaría el gesto sin modelo: banda roja en cada apertura")
    }

    @Test("con todo en su sitio, sí")
    func availableCanRun() async {
        let model = Self.model(catalog: ReservationTests.SpyCatalog(availability: .installed))
        await model.refreshDictationOffer(permission: .granted)
        #expect(model.dictationCanRun, "no armaría nunca: oferta \(String(describing: model.dictationOffer))")
    }

    @Test("sin permiso de micrófono, no")
    func deniedPermissionCannotRun() async {
        let model = Self.model(catalog: ReservationTests.SpyCatalog(availability: .installed))
        await model.refreshDictationOffer(permission: .denied)
        #expect(!model.dictationCanRun)
    }
}

/// Que la oferta se compruebe **al arrancar**, si el dictado quedó activado.
///
/// `dictationOffer` nace `nil` y `dictationCanRun` trata `nil` como «no puede». Es lo
/// correcto —el gesto no arma ante la duda—, pero mientras nadie poblara la oferta fuera de
/// Ajustes, quien activó el dictado en una sesión anterior mantenía el atajo y no pasaba
/// nada, en silencio, en cada arranque. La puerta principal muda y las secundarias vivas:
/// exactamente el patrón que este proyecto lleva diez rondas persiguiendo.
@Suite("La oferta se comprueba al arrancar")
@MainActor
struct StartupOfferTests {

    static func model(dictationEnabled: Bool, catalog: ReservationTests.SpyCatalog) throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ambar-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ambar.tests.startup.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        settings.isDictationEnabled = dictationEnabled
        let model = AppModel(settings: settings)
        model.catalogProvider = { _ in catalog }
        return (model, root)
    }

    @Test("con el dictado activado, arrancar comprueba la oferta")
    func enabledDictationRefreshesOnStart() async throws {
        let catalog = ReservationTests.SpyCatalog(availability: .installed)
        let (model, root) = try Self.model(dictationEnabled: true, catalog: catalog)
        defer { try? FileManager.default.removeItem(at: root) }
        // No depende del TCC real del proceso de test: lo que se prueba aquí es que
        // arrancar comprueba la oferta, no el estado de permisos de esta máquina.
        model.permissionProvider = { .granted }
        // Ni del hardware, que es por donde se coló: `hasInputDevice` enumera dispositivos
        // de captura reales, y en la VM del runner —sin entrada de audio— esa llamada se
        // comió los 3 s de plazo. El test declaraba no depender de la máquina y dependía.
        model.inputDeviceProvider = { true }

        #expect(model.dictationOffer == nil, "nace sin comprobar, que es lo correcto")
        model.refreshOfferIfDictationEnabled()
        // Por condición y no por reloj: con la suite cargada, 200 ms no garantizan que la
        // tarea haya corrido, y un test intermitente deja de significar nada.
        // Diez y no tres. La inyección de arriba quita la dependencia del hardware, pero
        // NO está medido que fuera la causa: aquí no se puede reproducir —esta máquina sí
        // tiene entrada de audio— y las otras trece llamadas a `refreshDictationOffer` de
        // este fichero no fallaron porque son `await` directos, sin plazo que agotar.
        // Ensanchar el plazo cubre la otra hipótesis —contención en una VM con la suite
        // corriendo en paralelo— y no afloja nada: si la oferta no llega nunca, esto falla
        // igual, solo que más tarde.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.dictationOffer == nil, ContinuousClock.now < deadline {
            // 25 ms, alineado con los dos bucles de `HoldGestureTests` y por el mismo
            // motivo medido allí: este sondeo comparte el actor principal con la tarea
            // cuya terminación espera, así que despertar más a menudo le quita turnos.
            // Son los tres únicos bucles de espera por condición de la suite.
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(model.dictationOffer != nil, "arrancó sin mirar: el gesto no armaría nunca")
        #expect(model.dictationCanRun, "el gesto seguiría muerto tras relanzar")
    }

    @Test("con el dictado apagado no se consulta nada")
    func disabledDictationDoesNotProbe() async throws {
        let catalog = ReservationTests.SpyCatalog(availability: .installed)
        let (model, root) = try Self.model(dictationEnabled: false, catalog: catalog)
        defer { try? FileManager.default.removeItem(at: root) }

        model.refreshOfferIfDictationEnabled()
        // Aquí sí se espera por reloj, y es correcto: lo que se afirma es que **no** pasa
        // nada, y eso no tiene condición que esperar. Un margen generoso hace el test más
        // exigente, no menos.
        try? await Task.sleep(for: .milliseconds(300))

        // §4: apagado significa que no se instancia nada. Ni una consulta al inventario de
        // idiomas del sistema.
        #expect(catalog.reserveCalls == 0, "consultó el inventario con el dictado apagado")
        #expect(model.dictationOffer == nil)
    }
}

/// La instalación del modelo avisa a VoiceOver, al empezar y al acabar.
///
/// Hallazgo de la auditoría de cierre (F6): el progreso de instalación del modelo se
/// pintaba como una barra visual sin ningún anuncio hablado — quien pulsa «Instalar» y
/// usa VoiceOver no se entera de que empezó a descargar ni de que terminó, solo de que
/// algo apareció y desapareció en algún momento indeterminado.
@Suite("La instalación del modelo avisa a VoiceOver", .serialized)
@MainActor
struct ModelInstallAnnouncementTests {

    static func model(catalog: ReservationTests.SpyCatalog) -> AppModel {
        let settings = Settings(defaults: UserDefaults(suiteName: "ambar.tests.install-announce.\(UUID().uuidString)")!)
        let model = AppModel(settings: settings)
        model.catalogProvider = { _ in catalog }
        return model
    }

    @Test("instalar con éxito anuncia el inicio y el final")
    func successfulInstallAnnouncesStartAndFinish() async {
        let model = Self.model(catalog: ReservationTests.SpyCatalog())
        var announced: [String] = []
        model.installAnnouncer = { announced.append($0) }

        await model.installDictationModel { _ in }

        #expect(
            announced == [
                String(localized: "dictation.model.installing", bundle: .localized),
                String(localized: "dictation.model.installed.announcement", bundle: .localized),
            ],
            "no avisó al empezar y al acabar, en ese orden: \(announced)"
        )
    }

    @Test("una instalación fallida también avisa, del fallo")
    func failedInstallAnnouncesTheFailure() async {
        let catalog = ReservationTests.SpyCatalog()
        catalog.failNextInstall()
        let model = Self.model(catalog: catalog)
        var announced: [String] = []
        model.installAnnouncer = { announced.append($0) }

        await model.installDictationModel { _ in }

        #expect(
            announced == [
                String(localized: "dictation.model.installing", bundle: .localized),
                String(localized: "dictation.model.failed", bundle: .localized),
            ],
            "un fallo silencioso: \(announced)"
        )
    }
}

/// Instalar el modelo pide un idioma **ya resuelto**.
///
/// `supportedLocale(equivalentTo:)` no es determinista: medido con el framework real, 40
/// llamadas con `de` reparten entre `de_AT` y `de_DE`, y con `fr` entre `fr_BE`, `fr_CH` y
/// `fr_FR`. Pasarle `Locale.current` sin resolver a `installModel` dejaba que el catálogo
/// resolviera por dentro, así que se podía **descargar una variante y comprobar otra**: el
/// usuario pulsa «Instalar», la descarga termina, y sigue leyendo «Falta el modelo de voz».
///
/// Lo encontró una auditoría independiente, y no tenía ninguna red: sustituir la llamada
/// por un identificador fijo sobrevivía a las 481 pruebas.
@Suite("La instalación del modelo no deja el idioma sin resolver", .serialized)
@MainActor
struct InstallResolvesLocaleTests {

    @Test("se instala la variante resuelta, no el idioma tal cual")
    func installUsesTheResolvedLocale() async throws {
        let catalog = ReservationTests.SpyCatalog()
        let model = ReservationTests.model(dictationEnabled: true, catalog: catalog)

        await model.installDictationModel { _ in }

        let pedidos = catalog.installedLocales
        #expect(pedidos.count == 1, "se pidió instalar \(pedidos.count) veces: \(pedidos)")
        // El doble resuelve a variantes regionales, igual que el framework. Si llegara el
        // identificador del sistema sin resolver, es que nadie lo resolvió antes.
        #expect(
            catalog.variants.contains(pedidos.first ?? ""),
            "se pidió instalar «\(pedidos.first ?? "nada")», que no es una variante resuelta"
        )
    }
}

/// La función se estrena en **diferido**, como promete §7.
///
/// «El modo con el que se estrena la función es el diferido, no el en vivo: es lo que §6.1
/// llama la protección real mientras no exista la medición, porque funciona en cualquier
/// máquina.»
///
/// La garantía vivía solo en `applyOfferedMode()`, que corre al activar el dictado. El
/// valor por defecto no estaba registrado y el `init` caía a `.live`, así que cualquier
/// estado con la función activada y la clave nunca escrita arrancaba en vivo. Lo midió una
/// auditoría independiente en la máquina de desarrollo: `defaults read` devolvía tres
/// claves, ninguna era esta, y el arnés imprimía `modo=live`. Cambiar el fallback a
/// `.deferred` no rompía nada, señal de que **nada** lo fijaba en ninguna dirección.
@Suite("El dictado se estrena en diferido", .serialized)
@MainActor
struct DefaultDictationModeTests {

    static func settings() throws -> Settings {
        let defaults = try #require(
            UserDefaults(suiteName: "dev.rrios.ambar.tests.mode.\(UUID().uuidString)"),
            "no se pudo crear un dominio de preferencias aislado"
        )
        return Settings(defaults: defaults)
    }

    @Test("sin nada escrito, el modo es diferido")
    func freshInstallStartsDeferred() throws {
        #expect(
            try Self.settings().dictationMode == .deferred,
            "la función se estrena en vivo, y §7 promete lo contrario"
        )
    }

    @Test("y con un valor ilegible, también")
    func unreadableValueFallsBackToDeferred() throws {
        let defaults = try #require(UserDefaults(suiteName: "dev.rrios.ambar.tests.mode.bad.\(UUID().uuidString)"))
        defaults.set("modo-que-no-existe", forKey: "dictation.mode")

        // El fallback del `init` tiene que decir lo mismo que lo registrado: si dijeran
        // cosas distintas, cuál gana dependería de si el registro llegó a correr.
        #expect(
            Settings(defaults: defaults).dictationMode == .deferred,
            "un valor ilegible estrena la función en vivo"
        )
    }

    @Test("lo que el usuario elige manda sobre el valor de estreno")
    func theUserChoiceWins() throws {
        let settings = try Self.settings()
        settings.dictationMode = .live

        // La otra mitad: si el diferido se impusiera siempre, no sería un valor de estreno
        // sino una imposición, y §7 dice «deja de aplicarse en cuanto el usuario elige».
        #expect(settings.dictationMode == .live, "no se respetó la elección del usuario")
    }
}
