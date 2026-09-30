import AppKit
import Foundation

/// Dónde vive la app, y si conviene llevarla a Aplicaciones antes de configurarla.
///
/// **Por qué existe.** Los permisos que Ámbar necesita —Accesibilidad, y el micrófono si
/// se activa el dictado— los concede el usuario a *una* copia de la app, identificada por
/// su firma y por dónde está. Conceder el permiso a la copia que está dentro de la imagen
/// de disco recién descargada, o en la carpeta de Descargas, y mover la app después, es la
/// forma conocida de perderlo: el permiso sigue registrado para algo que ya no está ahí, y
/// el síntoma es el peor posible —el interruptor aparece activado en Ajustes del Sistema y
/// el pegado no funciona—.
///
/// Lo que el repositorio ya tiene medido es la mitad hermana de esto: con firma ad-hoc,
/// **cada compilación** produce una firma distinta y el sistema revoca el permiso (ver el
/// apartado del README sobre `setup-signing.sh`). Aquí no se afirma el mecanismo interno de
/// TCC —no hace falta—: basta con ordenar los pasos de forma que el permiso se conceda
/// **después** de que la app esté en su sitio definitivo. Por eso este paso va antes que el
/// de Accesibilidad en la presentación.
///
/// La decisión y el efecto están separados a propósito: `decide` es una función pura sobre
/// hechos inyectables, y por tanto se puede probar sin mover nada del disco de quien corra
/// la suite.
public enum AppRelocation {
    /// Qué hacer con la ubicación actual de la app.
    public enum Decision: Equatable, Sendable {
        /// Ya vive en una carpeta de Aplicaciones. No hay nada que ofrecer.
        case alreadyInPlace

        /// Corre desde el árbol de compilación (`.build/`, `DerivedData/`).
        ///
        /// **No se ofrece nada.** En desarrollo la app se recompila y se relanza desde ahí
        /// muchas veces al día; ofrecer el traslado en cada arranque sería insufrible, y
        /// aceptarlo dejaría en Aplicaciones una copia firmada ad-hoc que queda obsoleta a
        /// la siguiente compilación.
        case development

        /// Está en un volumen de solo lectura: la imagen de disco desde la que se abrió.
        ///
        /// Copiar y no mover, porque mover es imposible: el origen no se puede modificar.
        /// La imagen queda montada y la expulsa el usuario.
        case offerCopy(from: URL, to: URL)

        /// Está en cualquier otro sitio escribible —Descargas, Escritorio, una carpeta
        /// cualquiera—. Se mueve, para no dejar dos copias que divergen.
        case offerMove(from: URL, to: URL)

        /// El destino que propone, si propone alguno.
        public var destination: URL? {
            switch self {
            case .alreadyInPlace, .development: nil
            case let .offerCopy(_, to), let .offerMove(_, to): to
            }
        }

        /// ¿Hay algo que ofrecerle al usuario?
        public var isOffer: Bool { destination != nil }
    }

    /// Carpetas que cuentan como «su sitio».
    ///
    /// `~/Applications` cuenta: es la ubicación correcta para quien no es administrador de
    /// su Mac, y tratarla como «hay que mover» le pediría algo que no puede hacer.
    static func applicationsDirectories(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Decide qué ofrecer, a partir de dónde está la app.
    ///
    /// - Parameters:
    ///   - bundleURL: el `.app` en ejecución (`Bundle.main.bundleURL`).
    ///   - home: la carpeta de inicio del usuario.
    ///   - isReadOnlyVolume: si el volumen que contiene una ruta es de solo lectura.
    ///     Inyectable porque montar una imagen de disco dentro de la suite sería un test
    ///     sobre el sistema de ficheros, no sobre esta decisión.
    public static func decide(
        bundleURL: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isReadOnlyVolume: (URL) -> Bool = AppRelocation.volumeIsReadOnly
    ) -> Decision {
        let bundle = bundleURL.standardizedFileURL
        let parent = bundle.deletingLastPathComponent().standardizedFileURL

        for directory in applicationsDirectories(home: home) {
            if parent.path == directory.standardizedFileURL.path { return .alreadyInPlace }
        }

        // El árbol de compilación se reconoce por sus carpetas, no por la ruta completa:
        // el worktree vive en un sitio distinto en cada sesión.
        let components = Set(bundle.pathComponents)
        if components.contains(".build") || components.contains("DerivedData") {
            return .development
        }

        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(bundle.lastPathComponent)

        return isReadOnlyVolume(bundle)
            ? .offerCopy(from: bundle, to: destination)
            : .offerMove(from: bundle, to: destination)
    }

    /// ¿Es de solo lectura el volumen que contiene esta ruta?
    ///
    /// Es lo que distingue «abierta desde la imagen de disco» de «abierta desde Descargas»,
    /// y se le pregunta al sistema en vez de comparar contra `/Volumes`: hay volúmenes
    /// escribibles montados ahí (un disco externo) e imágenes montadas en otro sitio.
    public static func volumeIsReadOnly(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    // MARK: - El efecto

    public enum RelocationError: Error, Equatable {
        /// Ya hay algo con ese nombre en Aplicaciones. No se pisa sin permiso explícito:
        /// podría ser una versión que el usuario quiere conservar, o la misma app abierta.
        case destinationExists(URL)
        /// El sistema de ficheros dijo no. El caso típico es no tener permiso de escritura
        /// en `/Applications` sin ser administrador.
        case failed(String)
    }

    /// Lleva la app a su destino y devuelve dónde quedó.
    ///
    /// No pide autenticación de administrador ni intenta escalar privilegios: si
    /// `/Applications` no es escribible, esto falla con un motivo que la interfaz puede
    /// contar, y el usuario arrastra la app a mano. Una app de portapapeles pidiendo la
    /// contraseña del Mac en su primer arranque es exactamente lo que no queremos.
    @discardableResult
    public static func perform(
        _ decision: Decision,
        replacingExisting: Bool = false,
        fileManager: FileManager = .default
    ) throws -> URL {
        let source: URL
        let destination: URL
        let copies: Bool

        switch decision {
        case .alreadyInPlace, .development:
            // No es un error del usuario ni algo que la interfaz pueda provocar: es un
            // programa que llamó a `perform` sobre una decisión que no ofrecía nada.
            throw RelocationError.failed("no hay traslado que hacer")
        case let .offerCopy(from, to):
            source = from; destination = to; copies = true
        case let .offerMove(from, to):
            source = from; destination = to; copies = false
        }

        if fileManager.fileExists(atPath: destination.path) {
            guard replacingExisting else { throw RelocationError.destinationExists(destination) }
            // A la papelera, no borrado: si el usuario se arrepiente —o si la copia que
            // había era la buena— tiene vuelta atrás. Borrar la app de alguien sin red de
            // seguridad no es una operación que este paso deba hacer.
            do {
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
            } catch {
                throw RelocationError.failed(error.localizedDescription)
            }
        }

        do {
            if copies {
                try fileManager.copyItem(at: source, to: destination)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        } catch {
            throw RelocationError.failed(error.localizedDescription)
        }

        return destination
    }

    /// Abre la copia que está en su sitio y termina esta.
    ///
    /// En este orden y con instancia nueva: sin `createsNewApplicationInstance`, el sistema
    /// ve la misma identidad de bundle ya en ejecución y se limita a activar **esta**
    /// copia —la que está a punto de morir—, con lo que el usuario se queda sin app y con
    /// el atajo global sin registrar.
    @MainActor
    public static func relaunch(at url: URL, terminate: @escaping @MainActor () -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in terminate() }
        }
    }
}
