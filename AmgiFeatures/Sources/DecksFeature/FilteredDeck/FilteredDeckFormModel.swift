//
//  FilteredDeckFormModel.swift
//  DecksFeature
//
//  Created by Junjie Chen on 22.10.2026.
//

import OSLog
import AppCore
import AppShared
import AnkiKit
import AnkiClients
import Dependencies
import Foundation

/// State and I/O for the create / edit filtered deck form. The draft comes
/// from the backend (its defaults for a new deck, or the saved settings of
/// an existing one) so every field the form does not show round-trips as is.
@Observable
@MainActor
final class FilteredDeckFormModel {
    struct OrderOption: Identifiable, Hashable {
        let order: FilteredDeckOrder
        let label: String
        var id: Int32 { order.rawValue }
    }

    enum LoadState {
        case loading
        case loaded
        case failed(String)
    }

    /// 0 when creating.
    let deckId: DeckID
    var isNew: Bool { deckId.rawValue == 0 }

    private(set) var loadState: LoadState = .loading
    private(set) var orderOptions: [OrderOption] = []
    private(set) var isSaving = false

    var name = ""
    var search = ""
    var limitText = ""
    var order: FilteredDeckOrder = .random
    var reschedule = true

    @ObservationIgnored private var draft: FilteredDeckDraft?
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.collectionStore) private var store

    /// Desktop Anki caps the limit spin box at 99 999.
    static let maxLimit = 99_999

    init(deckId: DeckID = DeckID(0)) {
        self.deckId = deckId
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var limit: Int? {
        guard let value = Int(limitText.trimmingCharacters(in: .whitespaces)),
              (1...Self.maxLimit).contains(value) else { return nil }
        return value
    }

    var canSave: Bool {
        guard case .loaded = loadState else { return false }
        return !isSaving && !trimmedName.isEmpty && limit != nil
    }

    func load() async {
        do {
            let draft = try await deckClient.fetchFilteredDeck(deckId)
            let labels = (try? await deckClient.filteredDeckOrderLabels()) ?? []
            orderOptions = Self.orderOptions(labels: labels, including: draft.order)
            self.draft = draft
            name = draft.name
            // A new deck starts from an empty search rather than the backend's
            // "<current deck> is:due" template: this form is for choosing
            // cards by topic, and due-only would hide not-yet-due cards.
            search = isNew ? "" : draft.search
            limitText = String(draft.limit)
            order = draft.order
            reschedule = draft.reschedule
            loadState = .loaded
        } catch {
            Log.decks.error("Loading filtered deck \(self.deckId.rawValue) failed: \(error)")
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Saves and rebuilds the deck. Returns the saved deck, or an error
    /// message to surface. A second call while one is in flight is a no-op.
    func save() async -> Result<DeckInfo, SaveError> {
        guard !isSaving else { return .failure(.inFlight) }
        guard var draft, let limit else { return .failure(.message("Enter a card limit between 1 and \(Self.maxLimit).")) }
        isSaving = true
        defer { isSaving = false }

        draft.name = trimmedName
        draft.search = search
        draft.limit = limit
        draft.order = order
        draft.reschedule = reschedule
        do {
            let creation = try await deckClient.saveFilteredDeck(draft)
            // Building moves cards between decks; refresh counts and queues
            // even if the backend's op report is narrower.
            store.apply(creation.changes.union(CollectionChanges(card: true, deck: true, studyQueues: true)))
            return .success(DeckInfo(id: creation.id, name: draft.name, isFiltered: true))
        } catch {
            Log.decks.error("Saving filtered deck failed: \(error)")
            return .failure(.message(error.localizedDescription))
        }
    }

    enum SaveError: Error, Equatable {
        case inFlight
        case message(String)
    }

    /// One option per backend label, in raw-value order. Falls back to the
    /// common orders when the labels can't be fetched, and always keeps the
    /// deck's current order selectable.
    static func orderOptions(labels: [String], including current: FilteredDeckOrder) -> [OrderOption] {
        var options = labels.enumerated().map {
            OrderOption(order: FilteredDeckOrder(rawValue: Int32($0.offset)), label: $0.element)
        }
        if options.isEmpty {
            options = [
                OrderOption(order: .random, label: "Random"),
                OrderOption(order: .added, label: "Order added"),
                OrderOption(order: .due, label: "Order due"),
                OrderOption(order: .oldestSeenFirst, label: "Oldest seen first"),
            ]
        }
        if !options.contains(where: { $0.order == current }) {
            options.append(OrderOption(order: current, label: "Order \(current.rawValue)"))
        }
        return options
    }
}
