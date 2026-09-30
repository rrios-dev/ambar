import Foundation

/// Por qué se abandonó el gesto antes de empezar a escuchar.
///
/// Se distinguen porque el diseño exige que **cualquier interacción cancele la
/// cuenta**: quien busca algo en la lista mueve el ratón, teclea o pulsa una
/// flecha; quien quiere dictar se queda quieto. Guardar la causa permite además
/// ver en depuración si el umbral está pisando el uso normal del historial.
public enum CancellationCause: String, Sendable, Equatable, CaseIterable {
    /// Se soltó el atajo antes de completar la cuenta. Es el caso normal.
    case releasedEarly
    case pointerMoved
    case typed
    case navigated
    case scrolled
    /// El panel se cerró (⎋, clic fuera, otra app tomó el foco).
    case panelDismissed
}

/// Por qué falló una sesión.
public enum DictationFailure: String, Sendable, Equatable, CaseIterable {
    /// El permiso de micrófono no está concedido. No debería llegarse aquí: la
    /// función no se ofrece sin permiso (`DictationReadiness.offer`). Existe
    /// porque el permiso puede revocarse mientras la app está abierta.
    case permissionDenied
    /// El modelo del idioma dejó de estar disponible.
    case modelUnavailable
    /// El dispositivo de entrada cambió a mitad de sesión y el formato negociado
    /// dejó de valer. No se intenta continuar con un formato inválido.
    case audioDeviceChanged
    case engineFailed
    /// La sesión llegó a su duración máxima y se descartó.
    ///
    /// Se descarta y no se entrega a propósito: el techo existe para cuando nadie
    /// quiso dictar, así que entregar sería pegar audio ambiente en el documento de
    /// alguien.
    case sessionLimitReached
    /// El cupo de idiomas del sistema está lleno.
    ///
    /// Necesita su propio caso porque el remedio es distinto y el contrato lo exige:
    /// «se dice qué liberar en lugar de fallar con un error que el usuario no puede
    /// interpretar». Colapsado en `modelUnavailable` se le decía a alguien que
    /// instalara un modelo que ya tenía.
    case languageQuotaFull
    /// La sesión terminó sin una sola palabra reconocida.
    ///
    /// Es el fallo más frecuente en la práctica —entrada silenciada, dispositivo de
    /// entrada equivocado, hablar demasiado bajo— y necesita su propio mensaje: sin
    /// él, el banner desaparecía sin decir nada y era indistinguible de una app rota.
    case noSpeechDetected
}

/// Estado de una sesión de dictado.
///
/// El orden no es decorativo: es lo que garantiza que **el micrófono solo esté
/// abierto en `listening`**. La preparación del modelo —que es la parte cara—
/// ocurre durante la cuenta del gesto y sin tocar el micrófono, de modo que al
/// confirmar solo queda abrir la entrada de audio.
public enum DictationSessionState: Sendable, Equatable {
    case idle

    /// La cuenta del gesto. `progress` va de 0 a 1 y es lo que la interfaz
    /// representa —animada o por pasos, según Reduce Motion—. `prepared` dice si
    /// el modelo ya terminó de cargarse mientras el usuario mantenía el atajo.
    ///
    /// Aquí el micrófono **no** está abierto: soltar en este punto no deja rastro
    /// ni enciende el indicador del sistema.
    case arming(progress: Double, prepared: Bool)

    /// La cuenta terminó pero el modelo aún no está listo. Estado de espera
    /// corto y visible; el micrófono sigue cerrado.
    case preparing

    /// Escuchando. **El único estado con el micrófono abierto.**
    case listening

    /// Se soltó el atajo y se está esperando a que el texto deje de ser volátil.
    /// Con techo: al vencerlo se entrega lo que haya.
    case finalizing

    case delivered(Transcript)
    case failed(DictationFailure)

    /// Avance mínimo para pintar la cuenta. Ver `deservesDisplay`.
    public static let armingDisplayThreshold = 0.33

    /// Identidad del estado **para animar**, sin el avance dentro.
    ///
    /// La animación de la banda se dispara con `value:`, y con el estado entero ese valor
    /// cambiaba en **cada tic de 40 ms** —`progress` vive dentro de `.arming`—, así que el
    /// `easeOut` se aplicaba también al ancho de la cápsula del indicador: la representación
    /// del umbral iba hasta 220 ms por detrás del umbral que representa, o sea subestimando
    /// cuánto queda para que se abra el micrófono.
    ///
    /// Y con «Reducir movimiento» no pasaba, porque ahí no hay animación: el camino
    /// accesible era el fiel y el camino por defecto el engañoso. Justo al revés de lo que
    /// §8.4 pretende.
    public var animationIdentity: String {
        switch self {
        case .idle: "idle"
        // La cuenta cuenta como **dos** valores, no uno: antes y después del umbral en el
        // que la banda aparece.
        //
        // Con un solo valor, `animationIdentity` valía «arming» desde `progress = 0` y no
        // cambiaba al cruzar el umbral, que es exactamente el instante en que la banda se
        // inserta: `.animation(_:value:)` solo abre transacción animada cuando el valor
        // cambia, así que la aparición volvía a ocurrir en un frame —el corte seco que este
        // mecanismo existe para quitar— mientras la salida sí se animaba. El arreglo de la
        // ronda 8 quitó el arrastre de la barra y se llevó por delante la animación que lo
        // motivaba todo.
        //
        // Sigue sin incluir el avance: dentro de cada tramo el valor es constante, así que
        // los tics de 40 ms no reabren la transacción ni arrastran la barra.
        case .arming(let progress, _):
            progress >= Self.armingDisplayThreshold ? "arming.visible" : "arming"
        case .preparing: "preparing"
        case .listening: "listening"
        case .finalizing: "finalizing"
        case .delivered: "delivered"
        case .failed: "failed"
        }
    }

    /// ¿Está el micrófono abierto en este estado?
    ///
    /// Es la traducción a código de una promesa del producto, y por eso existe
    /// como propiedad derivada de un único sitio en lugar de como una bandera
    /// que alguien pueda olvidar de actualizar. El test que la recorre sobre
    /// todos los estados es la comprobación de esa promesa.
    public var isMicrophoneOpen: Bool {
        if case .listening = self { return true }
        return false
    }

    /// ¿Debe el panel negarse a cerrarse mientras está en este estado?
    ///
    /// El panel se oculta al perder la condición de ventana clave
    /// (`PanelController.onResignKey`). Con una sesión en marcha eso dejaría el
    /// micrófono abierto sin ninguna interfaz visible, que es exactamente el
    /// fallo que la auditoría marcó como bloqueante.
    ///
    /// `arming` no cuenta: ahí no hay nada abierto y cerrar el panel es una
    /// cancelación legítima.
    public var inhibitsPanelDismissal: Bool {
        switch self {
        case .preparing, .listening, .finalizing: true
        case .idle, .arming, .delivered, .failed: false
        }
    }

    /// ¿Hay una sesión que el usuario percibe como activa?
    public var isActive: Bool {
        switch self {
        case .idle, .delivered, .failed: false
        case .arming, .preparing, .listening, .finalizing: true
        }
    }

    /// ¿Debe la interfaz seguir mostrando algo en este estado?
    ///
    /// No basta con `isActive`: un fallo ocurre justo cuando la sesión deja de
    /// estar activa, así que gatear la interfaz por actividad hace que **todo
    /// fallo sea invisible** —sin micrófono, sin modelo, con el permiso
    /// revocado— y el usuario no distinga eso de una app rota. Y una entrega
    /// truncada hay que confesarla, no solo pegarla.
    public var deservesDisplay: Bool {
        switch self {
        case .idle: false
        // La cuenta solo se muestra cuando ha avanzado **de verdad**. Con `> 0` no
        // bastaba: el primer tick llega a los 40 ms con progreso 0,09, así que una
        // pulsación corriente de 130 ms ya pintaba y retiraba la banda, y con ella
        // saltaba la lista y desaparecía el botón de micrófono. Un tercio del umbral
        // es tiempo suficiente para distinguir «va a dictar» de «ha pulsado el atajo».
        case .arming(let progress, _): progress >= Self.armingDisplayThreshold
        case .preparing, .listening, .finalizing, .failed: true
        case .delivered(let transcript): transcript.wasTruncated
        }
    }
}

/// Lo que le ocurre a una sesión.
public enum DictationEvent: Sendable, Equatable {
    /// El atajo se pulsó y empieza la cuenta.
    case gestureBegan
    /// Se pidió dictar **sin** gesto: botón de micrófono o atajo local del panel.
    case startRequested
    /// Avance de la cuenta, de 0 a 1.
    case gestureProgressed(Double)
    /// La cuenta se abandonó.
    case gestureCancelled(CancellationCause)
    /// La cuenta llegó al final: el usuario confirmó que quiere dictar.
    case gestureCompleted
    /// El modelo terminó de cargarse. Puede llegar durante la cuenta o después.
    case preparationFinished
    /// El usuario soltó el atajo (o pulsó parar) con el micrófono abierto.
    case stopRequested
    /// El usuario quiere tirar lo dictado sin entregarlo.
    case discardRequested
    /// El texto dejó de ser volátil.
    case finalizationFinished(Transcript)
    /// Venció el techo de espera de la finalización: se entrega lo que hay.
    case finalizationTimedOut(Transcript)
    case failed(DictationFailure)
}

/// Transición de la máquina de estados.
///
/// Función pura y total: devuelve `nil` cuando el evento no es legal en ese
/// estado, en lugar de aplicarlo a medias. Quien la llama decide qué hacer con
/// una transición ilegal —registrarla, ignorarla—, pero nunca se queda con un
/// estado inventado.
public func reduce(
    _ state: DictationSessionState,
    _ event: DictationEvent
) -> DictationSessionState? {
    switch (state, event) {
    // Un fallo corta desde cualquier estado activo. Desde `idle` no: un fallo
    // sin sesión no es un fallo, es ruido.
    case (let current, .failed(let failure)) where current.isActive:
        return .failed(failure)

    case (.idle, .gestureBegan),
         (.delivered, .gestureBegan),
         (.failed, .gestureBegan):
        return .arming(progress: 0, prepared: false)

    // Sin gesto se va directo a preparar: no hay cuenta que mostrar, no hay tecla
    // que mantener, y pasar por `.arming` hacía dos daños — la interfaz pedía
    // «mantén para dictar» a quien pulsó un botón precisamente por no poder, y
    // cualquier movimiento del ratón cancelaba la sesión en silencio.
    case (.idle, .startRequested),
         (.delivered, .startRequested),
         (.failed, .startRequested):
        return .preparing

    case (.arming(_, let prepared), .gestureProgressed(let progress)):
        return .arming(progress: min(max(progress, 0), 1), prepared: prepared)

    case (.arming, .preparationFinished):
        guard case .arming(let progress, _) = state else { return nil }
        return .arming(progress: progress, prepared: true)

    case (.arming, .gestureCancelled):
        return .idle

    case (.arming(_, let prepared), .gestureCompleted):
        // Si el modelo ya está cargado se abre el micrófono ahora; si no, se
        // espera visiblemente. Nunca se abre antes de esta transición.
        return prepared ? .listening : .preparing

    case (.preparing, .preparationFinished):
        return .listening

    // Soltar durante la espera de preparación cancela sin haber abierto nada.
    case (.preparing, .gestureCancelled), (.preparing, .stopRequested):
        return .idle

    // Abortar con el micrófono ya abierto: el panel se cerró, o algo forzó el
    // final sin querer entregar. **Tiene que volver al reposo**: cancelar sin
    // transicionar dejaba el estado clavado en `.listening` para siempre, con el
    // icono de la barra afirmando que el micrófono estaba abierto, el panel sin
    // poder volver a cerrarse y el dictado inservible el resto de la sesión.
    // Con el micrófono ya abierto, **el gesto deja de gobernar la sesión**: soltar no la
    // corta. El gesto sirve para arrancar y las manos quedan libres; se para con ⏎, con el
    // botón o con ⌘D, que emiten `.stopRequested`.
    //
    // El modelo anterior —«mantener mientras hablas»— obligaba a sostener tres teclas
    // durante toda una conversación, y cualquier resbalón la cortaba a mitad.
    case (.listening, .gestureCancelled(let cause)):
        // Cerrar el panel **sí** cierra la sesión: el micrófono no puede quedarse abierto sin
        // nada en pantalla. Cualquier otra cancelación del gesto —soltar la tecla— ya no
        // gobierna una sesión abierta.
        return cause == .panelDismissed ? .idle : nil

    case (.finalizing, .gestureCancelled):
        return .idle

    case (.listening, .stopRequested):
        return .finalizing

    // Descartar es distinto de parar: parar entrega y pega, descartar tira.
    // Antes solo existía parar, así que un gesto disparado sin querer terminaba
    // escribiendo en el documento del usuario sin ninguna forma de evitarlo.
    case (.listening, .discardRequested), (.finalizing, .discardRequested),
         (.preparing, .discardRequested), (.arming, .discardRequested):
        return .idle

    case (.finalizing, .finalizationFinished(let transcript)),
         (.finalizing, .finalizationTimedOut(let transcript)):
        return .delivered(transcript)

    default:
        return nil
    }
}
