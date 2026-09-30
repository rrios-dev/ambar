import Foundation
import Testing

/// Cerrojo para los tests que tocan el **inventario de idiomas del sistema**.
///
/// `AssetInventory` es estado global de la máquina, no del proceso de test: reservar es coger
/// una de las cinco ranuras que comparten todas las apps. Con las suites corriendo en
/// paralelo, dos tests que reservan y liberan el mismo idioma se pisan, y el síntoma es un
/// fallo **intermitente** que se lee como «cupo lleno» y que depende del orden de ejecución.
///
/// Medido: `reservationMakesModelAvailable` falló 2 de 10 pasadas por esto. `.serialized`
/// dentro de una suite no basta —las suites siguen corriendo entre sí en paralelo—, así que
/// hace falta un cerrojo compartido.
///
/// ## Por qué no basta con que sea un actor
///
/// La versión anterior era `func exclusive(_ body:) async throws -> T { try await body() }`
/// y su comentario afirmaba «al ser un actor, las llamadas se serializan solas». **Es
/// falso, y lo midió una auditoría independiente**: los actores de Swift son
/// *reentrantes*, así que el `await body()` suspende la llamada y **libera el actor**,
/// dejando entrar a la siguiente. Con ocho tareas concurrentes, la ocupación simultánea
/// máxima dentro de `exclusive` era **8**, no 1 — es decir, cero exclusión mutua.
///
/// Lo que serializa un actor es el acceso a su **estado**, no la duración de una llamada
/// que se suspende. Para eso hace falta un cerrojo de verdad: una bandera de ocupación y
/// una cola de espera, con **paso de testigo** al soltar —`release` despierta al siguiente
/// sin bajar `isBusy`— para que no quede una ventana entre el despertar y la readquisición
/// por la que se cuele un tercero.
actor SystemInventoryLock {
    static let shared = SystemInventoryLock()

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard waiters.isEmpty else {
            // Testigo directo: `isBusy` se queda en `true` y pasa a ser del siguiente.
            waiters.removeFirst().resume()
            return
        }
        isBusy = false
    }

    /// Ejecuta el bloque con acceso exclusivo **de verdad** al inventario del sistema.
    func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

/// Que el cerrojo **excluya**, que es lo único que se le pide.
///
/// Existe porque la versión anterior no excluía nada y nadie lo notó: su comentario
/// afirmaba la garantía, la suite pasaba, y la intermitencia que decía haber resuelto solo
/// estaba tapada por el `.serialized` de una de las dos suites que lo usan. Una garantía de
/// concurrencia sin un test que la mida es una afirmación, no una garantía.
@Suite("El cerrojo del inventario excluye de verdad")
struct SystemInventoryLockTests {

    /// Contador de ocupación simultánea, con su máximo histórico.
    actor Occupancy {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    @Test("ocho tareas concurrentes nunca coinciden dentro del cerrojo")
    func concurrentCallersNeverOverlap() async throws {
        let lock = SystemInventoryLock()
        let occupancy = Occupancy()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await lock.exclusive {
                        await occupancy.enter()
                        // Un punto de suspensión DENTRO del cuerpo: es exactamente lo que
                        // rompía la versión anterior, porque suspender liberaba el actor.
                        try? await Task.sleep(for: .milliseconds(5))
                        await occupancy.leave()
                    }
                }
            }
        }

        let peak = await occupancy.peak
        #expect(peak == 1, "ocupación simultánea máxima \(peak): el cerrojo no excluye nada")
    }

    @Test("el cerrojo se suelta aunque el cuerpo lance")
    func lockIsReleasedOnThrow() async throws {
        // Sin el `defer`, un cuerpo que lanza dejaría el cerrojo tomado para siempre y la
        // suite entera se colgaría en la siguiente llamada — un cuelgue, no un rojo.
        struct Boom: Error {}
        let lock = SystemInventoryLock()

        await #expect(throws: Boom.self) {
            try await lock.exclusive { throw Boom() }
        }

        // Si el cerrojo hubiera quedado tomado, esto no volvería nunca.
        let reentered = try await lock.exclusive { true }
        #expect(reentered, "el cerrojo quedó tomado tras un cuerpo que lanzó")
    }
}
