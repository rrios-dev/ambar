import Foundation
import Testing

@testable import Ambar

/// The system refreshes its speech asset catalog in the background, and a running Ámbar
/// then reads an installed model as missing until it is quit and opened again. These
/// pin when Ámbar restarts itself for that, and that it never does so in a loop.
@Suite("Stale speech model", .serialized)
@MainActor
struct StaleSpeechModelTests {
    private static func model() -> AppModel {
        let defaults = UserDefaults(suiteName: "ambar.tests.stale-model.\(UUID().uuidString)")!
        return AppModel(settings: Settings(defaults: defaults))
    }

    @Test("a model never seen installed is not a stale one: no restart")
    func neverSeenInstalledDoesNotRestart() {
        let model = Self.model()
        var restarts = 0
        model.restartForStaleSpeechModel = { restarts += 1 }

        #expect(!model.recoverStaleSpeechModel())
        #expect(model.settings.lastStaleModelRestart == nil)
        #expect(restarts == 0)
    }

    @Test("a model seen installed restarts the app, after the banner has had its moment")
    func seenInstalledRestarts() async throws {
        let model = Self.model()
        model.markSpeechModelSeenInstalledForTesting()
        var restarts = 0
        model.restartForStaleSpeechModel = { restarts += 1 }

        #expect(model.recoverStaleSpeechModel())
        #expect(restarts == 0, "restarted before the user could read why")
        let deadline = ContinuousClock.now + AppModel.staleSpeechModelRestartDelay + .seconds(5)
        while restarts == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(restarts == 1)
        #expect(model.settings.lastStaleModelRestart != nil)
    }

    @Test("a second stale answer soon after a restart does not restart again")
    func cooldownStopsALoop() {
        let model = Self.model()
        model.markSpeechModelSeenInstalledForTesting()
        model.restartForStaleSpeechModel = {}
        let now = Date()
        model.settings.lastStaleModelRestart = now.addingTimeInterval(-60)

        #expect(!model.recoverStaleSpeechModel(now: now))

        let later = now.addingTimeInterval(AppModel.staleSpeechModelRestartCooldown)
        #expect(model.recoverStaleSpeechModel(now: later))
    }
}
