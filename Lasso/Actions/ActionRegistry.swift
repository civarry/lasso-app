import Foundation
import Observation

/// Holds the ordered set of registered actions and resolves which are relevant for a selection.
///
/// New feature → `registry.register(MyAction())`. The ActionBar renders `relevantActions(for:)`.
@MainActor
@Observable
final class ActionRegistry {
    private(set) var actions: [any CaptureAction] = []

    /// The app's default capability set. Order here is the tie-breaker within a priority band.
    static func makeDefault(intelligence: IntelligenceCoordinator) -> ActionRegistry {
        let registry = ActionRegistry()
        registry.register(OCRCopyAction())
        registry.register(TranslateAction())
        registry.register(SummarizeAction(intelligence: intelligence))
        registry.register(AskAIAction(intelligence: intelligence))
        registry.register(QRAction())
        registry.register(ColorPickerAction())
        return registry
    }

    func register(_ action: any CaptureAction) {
        actions.append(action)
    }

    /// Relevant actions for a context, sorted by `relevancePriority` then registration order.
    func relevantActions(for ctx: CaptureContext) -> [any CaptureAction] {
        actions
            .enumerated()
            .filter { $0.element.isRelevant(to: ctx) }
            .sorted {
                if $0.element.relevancePriority != $1.element.relevancePriority {
                    return $0.element.relevancePriority < $1.element.relevancePriority
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }
}
