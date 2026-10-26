import Foundation

/// Boundary to the OS. Tests replace actual clipboard, clock and key effects.
struct PasteDeliveryEnvironment {
    var now: () -> TimeInterval
    var read: () -> String?
    var write: (String) -> Bool
    var post: () -> PasteOutcome
    var schedule: (TimeInterval, @escaping () -> Void) -> Void
}

final class CompatibilityPasteOperation {
    private let text: String
    private let quietPeriod: TimeInterval
    private let environment: PasteDeliveryEnvironment
    private let targetIsFrontmost: () -> Bool
    private let completion: (PasteOutcome) -> Void
    private var started = false
    private var finished = false
    private var deadline = 0.0
    private var stableSince = 0.0

    init(text: String, quietPeriod: TimeInterval, environment: PasteDeliveryEnvironment,
         targetIsFrontmost: @escaping () -> Bool, completion: @escaping (PasteOutcome) -> Void) {
        self.text = text
        self.quietPeriod = quietPeriod
        self.environment = environment
        self.targetIsFrontmost = targetIsFrontmost
        self.completion = completion
    }

    func start() {
        guard !started, !finished else { return }
        started = true
        stableSince = environment.now()
        deadline = stableSince + PasteHelper.ClipboardDefensePolicy.maximumWait(for: quietPeriod)
        tick()
    }
    func cancel() { finish(.notSent(.superseded)) }

    private func tick() {
        guard !finished else { return }
        guard environment.now() < deadline else { finish(.notSent(.clipboardUnstable)); return }
        guard targetIsFrontmost() else { finish(.notSent(.targetNotFrontmost)); return }
        if environment.read() != text {
            guard environment.write(text) else { finish(.notSent(.clipboardWriteFailed)); return }
            stableSince = environment.now()
        }
        let now = environment.now()
        if now - stableSince >= quietPeriod {
            // Revalidate immediately at the OS boundary; a late timer isn't authorization.
            guard environment.now() < deadline else { finish(.notSent(.clipboardUnstable)); return }
            guard targetIsFrontmost() else { finish(.notSent(.targetNotFrontmost)); return }
            if environment.read() == text {
                finish(environment.post())
                return
            }
            guard environment.write(text) else { finish(.notSent(.clipboardWriteFailed)); return }
            stableSince = environment.now()
        }
        guard PasteHelper.ClipboardDefensePolicy.canStillSucceed(
            stableElapsed: max(0, environment.now() - stableSince),
            remainingBudget: max(0, deadline - environment.now()), stableWindow: quietPeriod
        ) else { finish(.notSent(.clipboardUnstable)); return }
        environment.schedule(0.05) { [weak self] in self?.tick() }
    }

    private func finish(_ outcome: PasteOutcome) {
        guard !finished else { return }
        finished = true
        completion(outcome)
    }
}
