//
//  DecksService.swift
//  AnkiServices
//
//  Created by Vladimir Gusev on 27.03.2026.
//

package import AnkiBackend
import AnkiProtoBridge
public import AnkiKit
public import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct DecksService: Sendable {
    public var fetchAll: @Sendable () throws -> [DeckInfo]
    public var fetchTree: @Sendable () throws -> [DeckTreeNode]
    public var countsForDeck: @Sendable (_ deckId: DeckID) throws -> DeckCounts
    public var setCurrentDeck: @Sendable (_ deckId: DeckID) throws -> Void
    public var getCurrentDeck: @Sendable () throws -> DeckInfo
    public var createDeck: @Sendable (_ name: String) throws -> DeckCreation
    public var renameDeck: @Sendable (_ deckId: DeckID, _ name: String) throws -> CollectionChanges
    public var removeDeck: @Sendable (_ deckId: DeckID) throws -> CollectionChanges
    public var rebuildFilteredDeck: @Sendable (_ deckId: DeckID) throws -> Int
    public var emptyFilteredDeck: @Sendable (_ deckId: DeckID) throws -> Void
    /// Settings of an existing filtered deck, or the backend's defaults for
    /// a new one when `deckId` is 0.
    public var filteredDeck: @Sendable (_ deckId: DeckID) throws -> FilteredDeckDraft
    /// Backend labels for every `FilteredDeckOrder`, indexed by raw value.
    public var filteredDeckOrderLabels: @Sendable () throws -> [String]
    /// Adds or updates a filtered deck and rebuilds it in one transaction.
    /// Rejects a blank name, a name another deck already has, and a
    /// non-positive limit before reaching the backend; the backend then
    /// rejects an invalid search or one matching no cards, rolling back.
    public var saveFilteredDeck: @Sendable (_ draft: FilteredDeckDraft) throws -> DeckCreation
    /// AND's picked tags or decks onto `search`, written by the backend.
    public var appendSearchTerms: @Sendable (_ selection: SearchTermSelection, _ search: String) throws -> String
    /// Cards a filtered deck built from `search` would gather, before its
    /// limit: the backend's own exclusions applied, and — when `deckId` is
    /// an existing filtered deck — that deck's current cards counted in.
    public var countFilterableCards: @Sendable (_ search: String, _ deckId: DeckID) throws -> Int
    /// Raises today's new/review limits for a deck by the given deltas —
    /// Anki's "custom study → increase today's limit".
    public var extendLimits: @Sendable (_ deckId: DeckID, _ newDelta: Int32, _ reviewDelta: Int32) throws -> Void
    public var fetchDeckConfigContext: @Sendable (_ deckId: DeckID) throws -> DeckConfigsForUpdate
    public var getDeckConfig: @Sendable (_ deckId: DeckID) throws -> DeckConfig
    public var updateDeckConfig: @Sendable (
        _ deckId: DeckID,
        _ config: DeckConfig,
        _ applyToChildren: Bool,
        _ fsrsEnabled: Bool,
        _ newCardsIgnoreReviewLimit: Bool,
        _ applyAllParentLimits: Bool,
        _ fsrsHealthCheck: Bool
    ) throws -> Void
    public var computeFsrsParams: @Sendable (_ request: FsrsOptimizeRequest) throws -> FsrsOptimizeResult
    public var simulateFsrsReview: @Sendable (_ request: FsrsSimulationRequest) throws -> FsrsReviewSimulation
    public var simulateFsrsWorkload: @Sendable (_ request: FsrsSimulationRequest) throws -> FsrsWorkloadSimulation
    /// Re-computes parameters for every preset reachable from the deck, using
    /// the supplied baseline config as the deck's selected preset. Routes
    /// through `updateDeckConfigs` with mode `.computeAllParams`.
    public var optimizeFsrsPresets: @Sendable (_ deckId: DeckID, _ config: DeckConfig) throws -> Void
    /// Switch the deck to an existing preset. The supplied config keeps its
    /// id so the backend reuses the row instead of creating a new one.
    public var selectDeckPreset: @Sendable (_ deckId: DeckID, _ config: DeckConfig, _ applyToChildren: Bool) throws -> Void
    /// Create a new preset (id reset to 0) and select it for the deck.
    public var createDeckPreset: @Sendable (_ deckId: DeckID, _ baseConfig: DeckConfig, _ name: String, _ applyToChildren: Bool) throws -> Void
    /// Delete a preset and switch the deck to a fallback preset in one call.
    public var deleteDeckPreset: @Sendable (_ deckId: DeckID, _ removingConfigId: DeckConfigID, _ fallbackConfig: DeckConfig, _ applyToChildren: Bool) throws -> Void
}

extension DecksService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return Self(
            fetchAll: {
                do {
                    return try backend.invoke(.deckTree()).sortedByName
                } catch {
                    return try backend.invoke(.deckNames).sortedByName
                }
            },
            fetchTree: {
                try backend.invoke(.deckTree())
            },
            countsForDeck: { deckId in
                let counts = try? backend.invoke(.deckCounts(for: deckId))
                return counts.flatMap { $0 } ?? .zero
            },
            setCurrentDeck: { deckId in
                try backend.invoke(.setCurrentDeck(deckId: deckId))
            },
            getCurrentDeck: {
                try backend.invoke(.getCurrentDeck)
            },
            createDeck: { name in
                let template = try backend.invoke(.newDeck)
                return try backend.invoke(.addDeck(template: template, name: name))
            },
            renameDeck: { deckId, name in
                try backend.invoke(.renameDeck(deckId: deckId, newName: name))
            },
            removeDeck: { deckId in
                try backend.invoke(.removeDecks(deckIds: [deckId]))
            },
            rebuildFilteredDeck: { deckId in
                try backend.invoke(.rebuildFilteredDeck(deckId: deckId))
            },
            emptyFilteredDeck: { deckId in
                try backend.invoke(.emptyFilteredDeck(deckId: deckId))
            },
            filteredDeck: { deckId in
                try backend.invoke(.getOrCreateFilteredDeck(deckId: deckId))
            },
            filteredDeckOrderLabels: {
                try backend.invoke(.filteredDeckOrderLabels)
            },
            saveFilteredDeck: { draft in
                try persistFilteredDeck(draft, backend: backend)
            },
            appendSearchTerms: { selection, search in
                try backend.invoke(.appendingSearchTerms(selection, to: search))
            },
            countFilterableCards: { search, deckId in
                try backend.invoke(.searchCardIds(query: filterableCardsQuery(search, deckId: deckId))).count
            },
            extendLimits: { deckId, newDelta, reviewDelta in
                try backend.invoke(.extendLimits(deckId: deckId, newDelta: newDelta, reviewDelta: reviewDelta))
            },
            fetchDeckConfigContext: { deckId in
                try backend.invoke(.deckConfigsForUpdate(deckId: deckId))
            },
            getDeckConfig: { deckId in
                let context = try backend.invoke(.deckConfigsForUpdate(deckId: deckId))
                let currentConfigId = context.currentDeck?.configID ?? DeckConfigID(0)
                if currentConfigId.rawValue != 0,
                   let matched = context.allConfig.first(where: { $0.config.id == currentConfigId })?.config {
                    return matched
                }
                if currentConfigId.rawValue != 0 {
                    return try backend.invoke(.deckConfig(for: currentConfigId))
                }
                if let defaults = context.defaults {
                    return defaults
                }
                throw BackendError(
                    kind: .invalidInput,
                    message: "Deck \(deckId.rawValue) has no valid config id and no defaults available"
                )
            },
            updateDeckConfig: { deckId, config, applyToChildren, fsrsEnabled, newCardsIgnoreReviewLimit, applyAllParentLimits, fsrsHealthCheck in
                let context = try backend.invoke(.deckConfigsForUpdate(deckId: deckId))
                let request = UpdateDeckConfigsRequest(
                    targetDeckID: deckId,
                    configs: [config],
                    mode: applyToChildren ? .applyToChildren : .normal,
                    cardStateCustomizer: context.cardStateCustomizer,
                    limits: context.currentDeck?.limits,
                    newCardsIgnoreReviewLimit: newCardsIgnoreReviewLimit,
                    fsrs: fsrsEnabled,
                    applyAllParentLimits: applyAllParentLimits,
                    fsrsHealthCheck: fsrsHealthCheck
                )
                try backend.invoke(.updateDeckConfigs(request))
            },
            computeFsrsParams: { request in
                try backend.invoke(.computeFsrsParams(request))
            },
            simulateFsrsReview: { request in
                try backend.invoke(.simulateFsrsReview(request))
            },
            simulateFsrsWorkload: { request in
                try backend.invoke(.simulateFsrsWorkload(request))
            },
            optimizeFsrsPresets: { deckId, config in
                let context = try backend.invoke(.deckConfigsForUpdate(deckId: deckId))
                let request = makeUpdateRequest(
                    deckId: deckId,
                    context: context,
                    configs: [config],
                    removed: [],
                    mode: .computeAllParams,
                    fsrs: true
                )
                try backend.invoke(.updateDeckConfigs(request))
            },
            selectDeckPreset: { deckId, config, applyToChildren in
                let context = try backend.invoke(.deckConfigsForUpdate(deckId: deckId))
                let request = makeUpdateRequest(
                    deckId: deckId,
                    context: context,
                    configs: [config],
                    removed: [],
                    mode: applyToChildren ? .applyToChildren : .normal,
                    fsrs: context.fsrs
                )
                try backend.invoke(.updateDeckConfigs(request))
            },
            createDeckPreset: { deckId, baseConfig, name, applyToChildren in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw BackendError(kind: .invalidInput, message: "Preset name can't be empty")
                }
                let context = try backend.invoke(.deckConfigsForUpdate(deckId: deckId))
                var newConfig = baseConfig
                newConfig.id = DeckConfigID(0)
                newConfig.name = trimmed
                let request = makeUpdateRequest(
                    deckId: deckId,
                    context: context,
                    configs: [newConfig],
                    removed: [],
                    mode: applyToChildren ? .applyToChildren : .normal,
                    fsrs: context.fsrs
                )
                try backend.invoke(.updateDeckConfigs(request))
            },
            deleteDeckPreset: { deckId, removingConfigId, fallbackConfig, applyToChildren in
                guard removingConfigId != fallbackConfig.id else {
                    throw BackendError(kind: .invalidInput, message: "Fallback preset must differ from removed preset")
                }
                let context = try backend.invoke(.deckConfigsForUpdate(deckId: deckId))
                let request = makeUpdateRequest(
                    deckId: deckId,
                    context: context,
                    configs: [fallbackConfig],
                    removed: [removingConfigId],
                    mode: applyToChildren ? .applyToChildren : .normal,
                    fsrs: context.fsrs
                )
                try backend.invoke(.updateDeckConfigs(request))
            }
        )
    }()
}

/// `DecksService.saveFilteredDeck`, taking the backend explicitly so tests
/// can drive it against a scratch collection.
package func persistFilteredDeck(_ draft: FilteredDeckDraft, backend: AnkiBackend) throws -> DeckCreation {
    var draft = draft
    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.search = draft.search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !draft.name.isEmpty else {
        throw BackendError(kind: .invalidInput, message: "Deck name can't be empty.")
    }
    guard draft.limit > 0 else {
        throw BackendError(kind: .invalidInput, message: "Card limit must be at least 1.")
    }
    // The backend would silently rename a clash to "Name+"; refuse instead
    // so the deck gets the name the user typed.
    if let existing = try existingDeckId(named: draft.name, backend: backend),
       existing != draft.id {
        throw BackendError(kind: .exists, message: "A deck named \"\(draft.name)\" already exists.")
    }
    return try backend.invoke(.addOrUpdateFilteredDeck(draft))
}

/// The search a filtered-deck rebuild runs for a term, so a count matches
/// what building would gather. A deck being edited gets its own cards back
/// before it rebuilds, so they count too.
package func filterableCardsQuery(_ search: String, deckId: DeckID) -> String {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? "" : "(\(trimmed)) "
    let scope = deckId.rawValue == 0 ? "-deck:filtered" : "(-deck:filtered or did:\(deckId.rawValue))"
    return "\(base)-is:suspended -is:buried \(scope)"
}

private func existingDeckId(named name: String, backend: AnkiBackend) throws -> DeckID? {
    do {
        return try backend.invoke(.deckIdByName(name))
    } catch let error as BackendError where error.kind == .notFoundError {
        return nil
    }
}

private func makeUpdateRequest(
    deckId: DeckID,
    context: DeckConfigsForUpdate,
    configs: [DeckConfig],
    removed: [DeckConfigID],
    mode: UpdateDeckConfigsMode,
    fsrs: Bool
) -> UpdateDeckConfigsRequest {
    UpdateDeckConfigsRequest(
        targetDeckID: deckId,
        configs: configs,
        removedConfigIds: removed,
        mode: mode,
        cardStateCustomizer: context.cardStateCustomizer,
        limits: context.currentDeck?.limits,
        newCardsIgnoreReviewLimit: context.newCardsIgnoreReviewLimit,
        fsrs: fsrs,
        applyAllParentLimits: context.applyAllParentLimits,
        fsrsHealthCheck: context.fsrsHealthCheck
    )
}

extension DecksService: TestDependencyKey {
    public static let testValue = DecksService()
}

extension DependencyValues {
    public var decksService: DecksService {
        get { self[DecksService.self] }
        set { self[DecksService.self] = newValue }
    }
}
