import Foundation
import Testing

@testable import AppCore

/// Dónde vive la app y qué se le ofrece al usuario.
///
/// La decisión se prueba entera con rutas inventadas y un predicado de volumen inyectado:
/// montar una imagen de disco dentro de la suite sería probar el sistema de ficheros. El
/// efecto —mover y copiar de verdad— sí se prueba, pero en un directorio temporal.
@Suite("Ubicación de la app")
struct AppRelocationTests {
    private let home = URL(fileURLWithPath: "/Users/prueba", isDirectory: true)

    private func decide(
        _ path: String,
        readOnly: Bool = false
    ) -> AppRelocation.Decision {
        AppRelocation.decide(
            bundleURL: URL(fileURLWithPath: path),
            home: home,
            isReadOnlyVolume: { _ in readOnly }
        )
    }

    // MARK: - Ya está en su sitio

    @Test("en /Applications no se ofrece nada")
    func inSystemApplications() {
        #expect(decide("/Applications/Ambar.app") == .alreadyInPlace)
    }

    /// `~/Applications` es la ubicación correcta para quien no es administrador de su Mac.
    /// Tratarla como «hay que mover» le pediría algo que no puede hacer.
    @Test("en ~/Applications tampoco")
    func inUserApplications() {
        #expect(decide("/Users/prueba/Applications/Ambar.app") == .alreadyInPlace)
    }

    @Test("una subcarpeta de Aplicaciones no cuenta como estar en su sitio")
    func nestedInApplications() {
        // `/Applications/Utilidades/Ambar.app` no es donde el sistema espera encontrarla, y
        // comparar por prefijo de ruta lo habría dado por bueno.
        #expect(decide("/Applications/Utilidades/Ambar.app").isOffer)
    }

    // MARK: - Desarrollo

    @Test("desde el árbol de compilación no se ofrece nada")
    func fromBuildTree() {
        #expect(decide("/Volumes/Trabajo/forge/native/.build/Ambar.app") == .development)
        #expect(decide("/Users/prueba/Library/Developer/Xcode/DerivedData/x/Ambar.app") == .development)
    }

    /// El worktree vive en una ruta distinta en cada sesión, así que la detección tiene que
    /// ser por componente y no por ruta completa.
    @Test("el árbol de compilación se reconoce esté donde esté")
    func buildTreeAnywhere() {
        #expect(decide("/tmp/cualquier/sitio/.build/Ambar.app") == .development)
    }

    // MARK: - Ofertas

    @Test("desde un volumen de solo lectura se ofrece copiar, no mover")
    func fromDiskImage() {
        let decision = decide("/Volumes/Ámbar 0.1.0/Ambar.app", readOnly: true)
        #expect(
            decision == .offerCopy(
                from: URL(fileURLWithPath: "/Volumes/Ámbar 0.1.0/Ambar.app"),
                to: URL(fileURLWithPath: "/Applications/Ambar.app")
            )
        )
    }

    @Test("desde Descargas se ofrece mover")
    func fromDownloads() {
        let decision = decide("/Users/prueba/Downloads/Ambar.app")
        #expect(
            decision == .offerMove(
                from: URL(fileURLWithPath: "/Users/prueba/Downloads/Ambar.app"),
                to: URL(fileURLWithPath: "/Applications/Ambar.app")
            )
        )
    }

    @Test("el destino conserva el nombre del bundle")
    func destinationKeepsName() {
        #expect(
            decide("/Users/prueba/Desktop/Ambar.app").destination
                == URL(fileURLWithPath: "/Applications/Ambar.app")
        )
    }

    @Test("solo las ofertas tienen destino")
    func onlyOffersHaveDestination() {
        #expect(AppRelocation.Decision.alreadyInPlace.destination == nil)
        #expect(AppRelocation.Decision.development.destination == nil)
        #expect(AppRelocation.Decision.alreadyInPlace.isOffer == false)
        #expect(AppRelocation.Decision.development.isOffer == false)
    }

    // MARK: - El efecto

    /// Un `.app` de mentira: una carpeta con un fichero dentro. Basta para afirmar que se
    /// mueve o se copia enteramente.
    private func makeBundle(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("hola".utf8).write(to: url.appendingPathComponent("marca"))
    }

    private func withTemporaryDirectory(_ work: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ambar-relocation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try work(root)
    }

    @Test("mover deja el bundle en el destino y lo quita del origen")
    func performMove() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("Ambar.app")
            let destination = root.appendingPathComponent("destino/Ambar.app")
            try makeBundle(at: source)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let result = try AppRelocation.perform(.offerMove(from: source, to: destination))

            #expect(result == destination)
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("marca").path))
            #expect(FileManager.default.fileExists(atPath: source.path) == false)
        }
    }

    @Test("copiar deja el bundle en los dos sitios")
    func performCopy() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("Ambar.app")
            let destination = root.appendingPathComponent("destino/Ambar.app")
            try makeBundle(at: source)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            _ = try AppRelocation.perform(.offerCopy(from: source, to: destination))

            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("marca").path))
            // El origen es una imagen de solo lectura: tiene que seguir intacto.
            #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("marca").path))
        }
    }

    /// Lo que había en el destino no se pisa sin permiso explícito: podría ser una versión
    /// que el usuario quiere conservar.
    @Test("con algo en el destino falla en vez de sobrescribir")
    func performRefusesToOverwrite() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("Ambar.app")
            let destination = root.appendingPathComponent("Ambar copia.app")
            try makeBundle(at: source)
            try makeBundle(at: destination)

            #expect(throws: AppRelocation.RelocationError.destinationExists(destination)) {
                try AppRelocation.perform(.offerMove(from: source, to: destination))
            }
            // Y el origen sigue donde estaba: un fallo no puede dejar la app a medio mover.
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test("una decisión sin oferta no se puede ejecutar")
    func performRejectsNonOffers() {
        #expect(throws: AppRelocation.RelocationError.self) {
            try AppRelocation.perform(.alreadyInPlace)
        }
        #expect(throws: AppRelocation.RelocationError.self) {
            try AppRelocation.perform(.development)
        }
    }
}
