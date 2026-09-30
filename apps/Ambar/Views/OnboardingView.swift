import AppCore
import AppKit
import GlassUI
import SwiftUI

/// La presentación de primer uso.
///
/// **Qué problema resuelve.** Antes de esto, el primer arranque de Ámbar era un icono nuevo
/// en la barra de menús y un diálogo del sistema pidiendo permiso de Accesibilidad, sin
/// contexto: la app no se había presentado, no había dicho qué hacía con lo que copias, y ya
/// estaba pidiendo el permiso más delicado que macOS concede. Quien decía «no» —lo razonable
/// ante eso— se quedaba con la mitad del producto y sin saber por qué.
///
/// El orden de los pasos lo decide `OnboardingFlow`, no esta vista.
struct OnboardingView: View {
    @Bindable var model: AppModel
    let coordinator: OnboardingCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // `GeometryReader` fuera del `ScrollView` para poder darle al contenido un
            // **mínimo** igual al alto visible: así los pasos que son una portada se centran
            // en el hueco entero en vez de quedarse arriba con media ventana vacía, y los que
            // crecen —el alemán y el ruso ocupan bastante más— siguen pudiendo desplazarse en
            // lugar de recortarse. Con un `frame` fijo se centraría igual pero cortaría el
            // texto largo, que es peor que un scroll.
            GeometryReader { proxy in
                ScrollView {
                    OnboardingStepView(
                        model: model,
                        step: coordinator.current,
                        relocation: coordinator.conditions.relocation
                    )
                    .padding(.horizontal, Metrics.Inset.pane)
                    .padding(.vertical, Metrics.Spacing.section)
                    // Centrado en los dos ejes, para todos los pasos. El bloque se centra en
                    // el hueco como en cualquier asistente del sistema —antes iba pegado
                    // arriba y dejaba 300 px de vacío debajo—, y quién decide el ancho de la
                    // columna es el paso: la alineación interna de su contenido no depende de
                    // esto.
                    .frame(
                        maxWidth: .infinity,
                        minHeight: proxy.size.height,
                        alignment: .center
                    )
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider().opacity(0.5)
            OnboardingFooter(coordinator: coordinator)
        }
        .frame(width: Metrics.onboardingWidth, height: Metrics.onboardingHeight)
    }
}

/// El contenido de un paso, sin la ventana que lo envuelve.
///
/// Separado de `OnboardingView` para que el arnés de revisión pueda rasterizarlo: la
/// ventana real mete el paso dentro de un `ScrollView`, y `ImageRenderer` **no** rasteriza
/// scroll views —delegan en vistas de AppKit que solo existen dentro de una ventana— así que
/// una captura de la jerarquía completa saldría vacía. Con el paso suelto, lo que se
/// rasteriza es exactamente lo que se pinta en pantalla.
struct OnboardingStepView: View {
    @Bindable var model: AppModel
    let step: OnboardingStep
    let relocation: AppRelocation.Decision

    var body: some View {
        Group {
            switch step {
            case .welcome: WelcomeStep()
            case .location: LocationStep(decision: relocation)
            case .accessibility: AccessibilityStep(model: model)
            case .invocation: InvocationStep(model: model)
            case .extras: ExtrasStep(model: model)
            case .finish: FinishStep(model: model)
            }
        }
        // Los pasos con controles se limitan al ancho de su tarjeta, y ese bloque lo centra el
        // contenedor. Sin este límite, la cabecera se alineaba con el borde de la ventana y la
        // tarjeta con el suyo: dos ejes distintos a 24 px, que es la clase de descuadre que no
        // se sabe nombrar pero se ve. Las portadas ocupan el ancho entero porque ya se
        // componen al eje.
        .frame(
            maxWidth: step.isCover ? .infinity : StepMetrics.column,
            alignment: step.isCover ? .center : .leading
        )
    }
}

/// El pie: volver, por dónde vas, y seguir.
struct OnboardingFooter: View {
    let coordinator: OnboardingCoordinator

    var body: some View {
        // Los puntos van en una capa propia, centrada en el ancho de la ventana, y los
        // botones encima a los lados. Con los tres en un `HStack` y dos `Spacer`, el centro
        // lo decide la diferencia de ancho entre «Atrás» y el botón principal —que además
        // cambia de rótulo en el último paso—, así que los puntos quedaban desplazados a la
        // izquierda y se movían al avanzar. Nadie mide eso; se ve.
        ZStack {
            ProgressDots(position: coordinator.position, total: coordinator.total)

            HStack(spacing: Metrics.Spacing.snug) {
                // El botón de volver **ocupa su sitio siempre**, invisible en el primer paso.
                // Sin esto, el pie se recolocaba al pasar del primer paso al segundo y el
                // botón de continuar —el que se acaba de pulsar— saltaba bajo el cursor.
                Button(String(localized: "onboarding.back", bundle: .localized)) {
                    coordinator.back()
                }
                .opacity(coordinator.isFirst ? 0 : 1)
                .disabled(coordinator.isFirst)
                .accessibilityHidden(coordinator.isFirst)

                Spacer(minLength: Metrics.Spacing.section)

                Button(action: { coordinator.advance() }) {
                    Text(
                        coordinator.isLast
                            ? String(localized: "onboarding.finish", bundle: .localized)
                            : String(localized: "onboarding.continue", bundle: .localized)
                    )
                    // Los dos rótulos tienen anchos muy distintos —«Continuar» frente a
                    // «Empezar a usar Ámbar»—; el mínimo evita que el botón encoja por
                    // debajo de la medida cómoda en el paso corto.
                    .frame(minWidth: 88)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Metrics.Inset.pane)
        .padding(.vertical, Metrics.Spacing.regular)
    }
}

/// Por dónde va la presentación, en puntos.
///
/// Puntos y no «3 de 6»: el número exacto de pasos no le importa a nadie —cambia según lo
/// que ya esté resuelto en esa máquina— y lo que la gente quiere saber es cuánto queda. Lo
/// que **sí** dice el número es la etiqueta de accesibilidad, porque una hilera de puntos no
/// se puede leer en voz alta.
struct ProgressDots: View {
    let position: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(total, 1), id: \.self) { index in
                // `.tertiary` para los pendientes, no `.quaternary`: medido en la captura en
                // modo oscuro, con el cuaternario los puntos por recorrer desaparecían y el
                // indicador dejaba de indicar cuánto queda, que es su único trabajo.
                Circle()
                    .fill(index == position ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 6, height: 6)
            }
        }
        // Se **representa** como un texto en vez de ocultar los hijos y ponerle nombre.
        //
        // Medido en el volcado del árbol real: con `accessibilityElement(children: .ignore)`
        // el indicador salía como `AXUnknown` con el nombre correcto, y un rol desconocido
        // deja a VoiceOver sin saber qué anunciar cuando el usuario lo alcanza recorriendo la
        // ventana. Con esto sale como `AXStaticText`, que es lo que es.
        .accessibilityRepresentation {
            Text(
                String(
                    format: String(localized: "a11y.onboarding.progress", bundle: .localized),
                    position,
                    total
                )
            )
        }
    }
}

// MARK: - Piezas comunes

/// Cabecera de un paso: símbolo, título y una frase.
///
/// Está factorizada porque los seis pasos la comparten, y con ella el título de cada paso
/// entra en el árbol de accesibilidad como encabezado —sin eso, VoiceOver recorre la
/// ventana sin poder saltar de sección en sección.
private struct StepHeader: View {
    let symbol: String
    let title: String
    /// El párrafo bajo el título. Se llama `detail` y no `body` porque `View` ya usa ese
    /// nombre para lo que se dibuja.
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // El símbolo dentro de una pastilla del color de acento muy rebajado.
            //
            // Suelto y a peso `light` —como estaba— se leía como un adorno perdido sobre el
            // título. Contenido en una forma, es la marca del paso: la misma pieza que usan
            // las hojas de ajustes del sistema para encabezar una sección.
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    // 22 y semibold, en la misma escala que la portada: con 19 el título de
                    // un paso pesaba menos que el nombre de un ajuste de los que hay debajo.
                    .font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(detail)
                    .font(.system(size: Metrics.FontSize.body))
                    .foregroundStyle(Color.informationalStrong)
                    .fixedSize(horizontal: false, vertical: true)
                    // Medida de línea acotada. A lo ancho de la ventana entera el párrafo
                    // pasaba de 95 caracteres, y en un paso que pide un permiso es
                    // precisamente el párrafo lo que hay que leer.
                    .frame(maxWidth: StepMetrics.cardContent, alignment: .leading)
            }
        }
    }
}

/// Una característica: símbolo, qué es y en una línea por qué importa.
///
/// Dos niveles y no uno. Una lista de frases de una sola línea obliga a elegir entre decir
/// qué hace la app o decir por qué está bien, y con el título en negrita y el detalle debajo
/// caben las dos cosas: la vista se recorre leyendo solo los títulos y el detalle está para
/// quien se pare. Es la fila de característica que usa el sistema en sus propias pantallas de
/// bienvenida, y la razón por la que la lista anterior se leía plana.
private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                // Monocromo y con peso medium, **no** jerárquico. Probado a este tamaño: el
                // renderizado jerárquico reparte el glifo en dos densidades y a 22 pt el
                // resultado es un contorno fino con el interior vacío —el reloj y el candado
                // se veían huecos—. En un símbolo pequeño la definición pesa más que el
                // matiz.
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                // Ancho fijo y alineado al centro: sin esto, los tres títulos empiezan en una
                // sangría distinta según lo ancho que sea cada glifo.
                .frame(width: 26, alignment: .center)
                // Empuja el símbolo hasta la línea de mayúsculas del título, que es donde el
                // ojo espera encontrarlo.
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: Metrics.FontSize.body, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.informational)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Las dos líneas se leen como una sola cosa; sin esto VoiceOver las anuncia como dos
        // elementos sin relación.
        .accessibilityElement(children: .combine)
    }
}

/// Agrupa lo que hay que hacer en un paso: los botones, los interruptores y sus notas.
///
/// **Por qué una tarjeta y no aire.** Con la cabecera arriba y los controles suel­tos debajo,
/// un paso quedaba como tres bloques flotando sobre 400 px de vacío: nada indicaba dónde
/// empieza «lo que tienes que decidir aquí». Encerrarlos en una superficie los convierte en
/// una unidad, y de paso resuelve el problema de la medida de línea —las notas heredan el
/// ancho de la tarjeta en lugar de estirarse hasta el borde de la ventana—.
///
/// El fondo es un estilo del sistema (`.quinary`) y no un color propio: sobre el material de
/// cristal tiene que ser el sistema quien decida cuánto se ve, igual que en el resto de la
/// app. Ver la nota de `GlassUI` sobre no definir colores.
/// Medidas de la columna de un paso.
///
/// Fuera de `StepCard` porque ese tipo es genérico en su contenido, y una constante ahí dentro
/// obligaría a nombrar el parámetro genérico en cada uso —`StepCard<AnyView>.width`— para leer
/// un número.
private enum StepMetrics {
    /// Ancho del contenido de la tarjeta. Acota la medida de línea de las notas.
    static let cardContent: CGFloat = 460
    /// Ancho total de la columna: el contenido más los márgenes internos de la tarjeta. Lo
    /// comparten la cabecera y la tarjeta para que ambas arranquen en el mismo eje.
    static let column: CGFloat = cardContent + Metrics.Spacing.loose * 2
}

private struct StepCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.regular) {
            content
        }
        .frame(maxWidth: StepMetrics.cardContent, alignment: .leading)
        .padding(Metrics.Spacing.loose)
        // **Sin altura mínima.** Hubo un suelo de 116 pt para que el bloque centrado no se
        // moviera al cambiar de estado, y el remedio salió peor que la enfermedad: en el paso
        // de ubicación, cuya tarjeta es un solo botón, dejaba 130 pt de tarjeta vacía debajo
        // —un defecto permanente que ve todo el mundo, para evitar un desplazamiento que solo
        // ocurre después de que el usuario pulse algo—. La tarjeta se ajusta a su contenido y
        // el cambio se anima donde puede ocurrir.
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Estado resuelto: lo que ya no hay que hacer, dicho en verde.
private struct ResolvedNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: Metrics.FontSize.caption))
                .foregroundStyle(Color.informationalStrong)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Pasos

/// La portada.
///
/// Composición en dos bloques: la cabecera al eje —icono, promesa, una frase— y debajo tres
/// características alineadas a la izquierda dentro de una columna centrada. Centrar también
/// las filas dejaría tres bloques de texto con el borde izquierdo en diente de sierra, que es
/// lo que hace que una pantalla parezca hecha a ojo.
///
/// La medida de línea está limitada a propósito: a lo ancho de la ventana entera, el subtítulo
/// pasaba de los 90 caracteres y nadie lee eso en una pantalla que quiere que pulses un botón.
private struct WelcomeStep: View {
    /// Ancho de la columna de lectura. Deja el texto en 55-70 caracteres por línea, que es
    /// la medida en la que el ojo vuelve al principio sin perderse.
    private let column: CGFloat = 420

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 14) {
                // El icono real del bundle, no un símbolo: es la única vez que la app puede
                // decir «esto es lo que acabas de instalar», y lo que hace que el glifo
                // monocromo de la barra de menús se asocie luego con ella.
                //
                // A 96 pt, que es la medida del icono en el panel «Acerca de» del sistema. A
                // 64 —lo que tenía— parecía la fila de una lista, no la portada de nada.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    // Sombra corta y muy suave: el icono es la única pieza que debe levantarse
                    // del material. Más radio o más opacidad y se nota el truco, sobre todo
                    // sobre cristal claro.
                    .shadow(color: .black.opacity(0.18), radius: 9, y: 3)
                    .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text(String(localized: "onboarding.welcome.title", bundle: .localized))
                        .font(.system(size: 26, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(String(localized: "onboarding.welcome.body", bundle: .localized))
                        // 15 y no 13: bajo un título de 26 pt, el cuerpo normal se lee como
                        // un pie de foto y la portada pierde su segunda línea de jerarquía.
                        .font(.system(size: 15))
                        .foregroundStyle(Color.informationalStrong)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: column)
            }

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    symbol: "clock.arrow.circlepath",
                    title: String(localized: "onboarding.welcome.point.history", bundle: .localized),
                    detail: String(localized: "onboarding.welcome.point.history_detail", bundle: .localized)
                )
                FeatureRow(
                    symbol: "text.viewfinder",
                    title: String(localized: "onboarding.welcome.point.search", bundle: .localized),
                    detail: String(localized: "onboarding.welcome.point.search_detail", bundle: .localized)
                )
                FeatureRow(
                    // `lock.shield` y no `lock.laptopcomputer`: ese es mucho más ancho que
                    // alto y su centro óptico cae por debajo de la línea del título, así que
                    // su fila se leía descolgada respecto a las otras dos. Los tres glifos de
                    // la columna tienen ahora proporción cuadrada.
                    symbol: "lock.shield",
                    title: String(localized: "onboarding.welcome.point.private", bundle: .localized),
                    detail: String(localized: "onboarding.welcome.point.private_detail", bundle: .localized)
                )
            }
            .frame(maxWidth: column, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Llevar la app a Aplicaciones, antes de pedir cualquier permiso.
private struct LocationStep: View {
    let decision: AppRelocation.Decision

    /// Qué ha pasado con el traslado. Arranca sin intentar nada.
    @State private var outcome: Outcome = .pending

    private enum Outcome: Equatable {
        case pending
        /// Hay una copia en el destino y hace falta confirmación para reemplazarla.
        case needsReplacement
        case failed(String)
        case done
    }

    private var copies: Bool {
        if case .offerCopy = decision { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.loose) {
            StepHeader(
                symbol: copies ? "square.and.arrow.down.on.square" : "folder",
                title: String(localized: "onboarding.location.title", bundle: .localized),
                detail: copies
                    ? String(localized: "onboarding.location.body.copy", bundle: .localized)
                    : String(localized: "onboarding.location.body.move", bundle: .localized)
            )

            StepCard {
                switch outcome {
                case .done:
                    ResolvedNote(text: String(localized: "onboarding.location.done", bundle: .localized))
                case .needsReplacement:
                    Text(String(localized: "onboarding.location.exists", bundle: .localized))
                        .font(.system(size: Metrics.FontSize.caption))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "onboarding.location.replace", bundle: .localized)) {
                        relocate(replacingExisting: true)
                    }
                case let .failed(reason):
                    Text(
                        String(
                            format: String(localized: "onboarding.location.failed", bundle: .localized),
                            reason
                        )
                    )
                    .font(.system(size: Metrics.FontSize.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    button
                case .pending:
                    button
                }
            }
        }
        // El alto de la tarjeta cambia al aparecer un aviso, y con el bloque centrado eso
        // desplaza lo de arriba. Animado se lee como una respuesta a lo que se acaba de
        // pulsar; de golpe, como un salto. `AccessibilityPreferences` devuelve `nil` cuando el
        // sistema pide reducir el movimiento, y entonces el cambio es instantáneo.
        .animation(
            AccessibilityPreferences.shared.animation(.smooth(duration: 0.22)),
            value: outcome
        )
    }

    private var button: some View {
        Button(
            copies
                ? String(localized: "onboarding.location.copy", bundle: .localized)
                : String(localized: "onboarding.location.move", bundle: .localized)
        ) {
            relocate(replacingExisting: false)
        }
    }

    private func relocate(replacingExisting: Bool) {
        do {
            let destination = try AppRelocation.perform(
                decision,
                replacingExisting: replacingExisting
            )
            outcome = .done
            // Se relanza desde el sitio nuevo y esta copia termina. No se sigue con la
            // presentación en el proceso viejo: los pasos que quedan conceden permisos, y
            // concederlos a un bundle que ya no existe —o que está dentro de una imagen a
            // punto de expulsarse— es exactamente el fallo que este paso evita.
            AppRelocation.relaunch(at: destination) { NSApp.terminate(nil) }
        } catch AppRelocation.RelocationError.destinationExists {
            outcome = .needsReplacement
        } catch let AppRelocation.RelocationError.failed(reason) {
            outcome = .failed(reason)
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }
}

/// El permiso que hace que `↵` pegue en la app donde estabas.
private struct AccessibilityStep: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.loose) {
            StepHeader(
                symbol: "hand.tap",
                title: String(localized: "onboarding.accessibility.title", bundle: .localized),
                detail: String(localized: "onboarding.accessibility.body", bundle: .localized)
            )

            StepCard {
                if model.canAutoPaste {
                    ResolvedNote(
                        text: String(localized: "onboarding.accessibility.granted", bundle: .localized)
                    )
                } else {
                    HStack(spacing: Metrics.Spacing.snug) {
                        // El diálogo del sistema solo aparece **una vez por firma de
                        // código**; después de eso no hay forma de volver a invocarlo, y por
                        // eso el acceso a Ajustes está al lado y no escondido tras un fallo.
                        // Sin `.borderedProminent`: el botón por defecto de la ventana es el
                        // del pie, y dos piezas azules a la vez dejan al ojo sin saber cuál
                        // avanza. La jerarquía entre estos dos la da el orden y el rótulo.
                        Button(String(localized: "permission.grant", bundle: .localized)) {
                            Paster.requestAccessibilityPermission()
                        }
                        Button(String(localized: "settings.open_settings", bundle: .localized)) {
                            Paster.openAccessibilitySettings()
                        }
                    }
                    Text(String(localized: "onboarding.accessibility.waiting", bundle: .localized))
                        .font(.system(size: Metrics.FontSize.caption))
                        .foregroundStyle(Color.informational)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.5)

                Text(String(localized: "onboarding.accessibility.optional", bundle: .localized))
                    .font(.system(size: Metrics.FontSize.caption))
                    .foregroundStyle(Color.informational)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Igual que en el paso de ubicación: conceder el permiso convierte dos botones en una
        // línea, y ese cambio llega **mientras el usuario está mirando** —viene de Ajustes del
        // Sistema, no de un clic aquí—, así que animarlo es lo que hace que se entienda como
        // «ya está» en vez de como un parpadeo.
        .animation(
            AccessibilityPreferences.shared.animation(.smooth(duration: 0.22)),
            value: model.canAutoPaste
        )
        // Concederlo ocurre fuera de la app y macOS no avisa: sin este sondeo el paso
        // seguiría diciendo que falta después de haberlo concedido, que es el momento en
        // que uno concluye que la app está rota. Lo apaga el controlador al cerrar la
        // ventana.
        .onAppear { model.refreshPermissionState() }
    }
}

/// Con qué teclas se abre, y si arranca al iniciar sesión.
private struct InvocationStep: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.loose) {
            StepHeader(
                symbol: "command",
                title: String(localized: "onboarding.invocation.title", bundle: .localized),
                detail: String(localized: "onboarding.invocation.body", bundle: .localized)
            )

            StepCard {
                HStack(spacing: Metrics.Spacing.regular) {
                    Text(String(localized: "settings.hotkey", bundle: .localized))
                        .font(.system(size: Metrics.FontSize.body))
                    ShortcutRecorder(
                        combination: Binding(
                            get: { model.settings.hotKey },
                            set: { newValue in
                                model.settings.hotKey = newValue
                                // Sin esto el ajuste se guarda y el sistema sigue escuchando
                                // el atajo anterior.
                                model.reloadHotKey()
                            }
                        )
                    )
                }

                // El paso que enseña el atajo es el sitio donde importa saber que no se pudo
                // registrar: se cambia aquí mismo, sin salir de la presentación.
                if model.isHotKeyUnavailable {
                    Text(String(localized: "hotkey.unavailable", bundle: .localized))
                        .font(.system(size: Metrics.FontSize.caption))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: Metrics.Spacing.tight) {
                    Toggle(
                        String(localized: "settings.launch_at_login", bundle: .localized),
                        isOn: Binding(
                            get: { model.settings.launchAtLogin },
                            set: { model.settings.launchAtLogin = $0 }
                        )
                    )
                    Text(String(localized: "onboarding.invocation.login_help", bundle: .localized))
                        .font(.system(size: Metrics.FontSize.caption))
                        .foregroundStyle(Color.informational)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Dictado y reconocimiento de texto: las dos que cuestan algo y por tanto se preguntan.
private struct ExtrasStep: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.loose) {
            StepHeader(
                symbol: "slider.horizontal.3",
                title: String(localized: "onboarding.extras.title", bundle: .localized),
                detail: String(localized: "onboarding.extras.body", bundle: .localized)
            )

            StepCard {
                VStack(alignment: .leading, spacing: Metrics.Spacing.tight) {
                    Toggle(
                        String(localized: "settings.dictation.enabled", bundle: .localized),
                        isOn: Binding(
                            get: { model.settings.isDictationEnabled },
                            set: { wanted in
                                guard wanted else {
                                    model.disableDictation()
                                    return
                                }
                                // Activar es lo que pide el permiso de micrófono. Nunca el
                                // gesto.
                                Task { await model.enableDictation() }
                            }
                        )
                    )
                    .disabled(model.isRequestingMicrophone)

                    Text(String(localized: "settings.dictation.help", bundle: .localized))
                        .font(.system(size: Metrics.FontSize.caption))
                        .foregroundStyle(Color.informational)
                        .fixedSize(horizontal: false, vertical: true)

                    // Qué falta, si falta algo: el permiso, el modelo del idioma, o que el
                    // idioma no esté admitido. Un interruptor que se enciende y no funciona es
                    // peor que uno que explica por qué no puede. Va **después** de la ayuda y
                    // no entre el interruptor y su explicación, que era donde partía la
                    // pareja en dos.
                    DictationOfferNote(offer: model.dictationOffer, model: model)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: Metrics.Spacing.tight) {
                    Toggle(
                        String(localized: "settings.ocr", bundle: .localized),
                        isOn: Binding(
                            get: { model.settings.isOCREnabled },
                            set: { model.settings.isOCREnabled = $0 }
                        )
                    )
                    Text(String(localized: "settings.ocr_help", bundle: .localized))
                        .font(.system(size: Metrics.FontSize.caption))
                        .foregroundStyle(Color.informational)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // La oferta se consulta al entrar en el paso: con el dictado apagado —que es el
        // valor de fábrica— es lo único que puede decir qué haría falta para encenderlo.
        .task { await model.refreshDictationOffer() }
    }
}

/// Cierre: cómo se abre, y en qué estado está el derecho de uso.
private struct FinishStep: View {
    @Bindable var model: AppModel

    /// La misma columna de lectura que la portada. Las dos pantallas que se leen y no se
    /// tocan comparten medida; si difirieran, pasar de una a otra se notaría como un salto.
    private let column: CGFloat = 420

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 14) {
                // Cierre al eje, como la portada, y no la cabecera alineada a la izquierda que
                // usan los pasos con controles: aquí no hay nada que tocar, solo una
                // confirmación que se lee de un vistazo.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text(String(localized: "onboarding.finish.title", bundle: .localized))
                        .font(.system(size: 26, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        String(
                            format: String(localized: "onboarding.finish.body", bundle: .localized),
                            model.settings.hotKey.displayString
                        )
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(Color.informationalStrong)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: column)
            }

            Text(String(localized: "onboarding.finish.settings_hint", bundle: .localized))
                .font(.system(size: 12))
                .foregroundStyle(Color.informational)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: column)
        }
        .frame(maxWidth: .infinity)
    }
}
