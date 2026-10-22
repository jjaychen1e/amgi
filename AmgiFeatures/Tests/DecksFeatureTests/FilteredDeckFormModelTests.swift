//
//  FilteredDeckFormModelTests.swift
//  DecksFeatureTests
//
//  Created by Junjie Chen on 22.10.2026.
//

import AppShared
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import Testing
@testable import DecksFeature

@MainActor
@Suite struct FilteredDeckFormModelTests {
    private actor Calls {
        var saved: [FilteredDeckDraft] = []
        func record(_ draft: FilteredDeckDraft) { saved.append(draft) }
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "No cards matched the provided search." }
    }

    private static let labels = [
        "Oldest seen first", "Random", "Increasing intervals", "Decreasing intervals",
        "Most lapses", "Order added", "Order due", "Latest added first",
        "Retrievability ascending", "Retrievability descending", "Relative overdueness",
    ]

    private func makeModel(
        deckId: DeckID = DeckID(0),
        save: @escaping @Sendable (FilteredDeckDraft) async throws -> DeckCreation
    ) -> FilteredDeckFormModel {
        var client = DeckClient()
        client.fetchFilteredDeck = { id in
            .preview(id: id)
        }
        let labels = Self.labels
        client.filteredDeckOrderLabels = { labels }
        client.saveFilteredDeck = save
        return withDependencies {
            $0.deckClient = client
        } operation: {
            let store = CollectionStore()
            return withDependencies {
                $0.collectionStore = store
            } operation: {
                FilteredDeckFormModel(deckId: deckId)
            }
        }
    }

    @Test func load_newDeck_startsWithAnEmptySearchAndAnkiDefaults() async {
        let model = makeModel { _ in DeckCreation(id: DeckID(5), changes: CollectionChanges()) }
        await model.load()
        #expect(model.isNew)
        #expect(model.search.isEmpty)
        #expect(model.reschedule)
        #expect(model.limitText == "100")
        #expect(model.order == .random)
        #expect(model.orderOptions.count == 11)
        #expect(model.canSave)
    }

    @Test func load_existingDeck_showsItsSavedSearch() async {
        let model = makeModel(deckId: DeckID(42)) { _ in DeckCreation(id: DeckID(42), changes: CollectionChanges()) }
        await model.load()
        #expect(!model.isNew)
        #expect(model.search == "tag:travel")
    }

    @Test func save_sendsTheEditedFields_andTrimsTheName() async throws {
        let calls = Calls()
        let model = makeModel { draft in
            await calls.record(draft)
            return DeckCreation(id: DeckID(7), changes: CollectionChanges())
        }
        await model.load()
        model.name = "  Travel  "
        model.search = #"deck:"English" tag:travel"#
        model.limitText = "25"
        model.order = .added
        model.reschedule = false

        guard case .success(let deck) = await model.save() else {
            Issue.record("save failed")
            return
        }
        #expect(deck == DeckInfo(id: DeckID(7), name: "Travel", isFiltered: true))
        let sent = try #require(await calls.saved.first)
        #expect(sent.name == "Travel")
        #expect(sent.search == #"deck:"English" tag:travel"#)
        #expect(sent.limit == 25)
        #expect(sent.order == .added)
        #expect(sent.reschedule == false)
    }

    @Test func secondTap_whileSaving_doesNotSaveTwice() async {
        let calls = Calls()
        let model = makeModel { draft in
            await calls.record(draft)
            try await Task.sleep(for: .milliseconds(200))
            return DeckCreation(id: DeckID(7), changes: CollectionChanges())
        }
        await model.load()
        model.name = "Travel"

        let first = Task { await model.save() }
        while !model.isSaving { await Task.yield() }
        let second = await model.save()
        _ = await first.value

        #expect(second == .failure(.inFlight))
        #expect(await calls.saved.count == 1)
        #expect(!model.isSaving)
    }

    @Test func backendError_isSurfaced_andTheFormStaysEditable() async {
        let model = makeModel { _ in throw Failure() }
        await model.load()
        model.name = "Nothing"
        #expect(await model.save() == .failure(.message("No cards matched the provided search.")))
        #expect(!model.isSaving)
        #expect(model.canSave)
    }

    @Test func invalidInput_disablesSave() async {
        let model = makeModel { _ in DeckCreation(id: DeckID(7), changes: CollectionChanges()) }
        await model.load()
        model.name = "   "
        #expect(!model.canSave)
        model.name = "Travel"
        model.limitText = "0"
        #expect(!model.canSave)
        model.limitText = "abc"
        #expect(!model.canSave)
        model.limitText = "50"
        #expect(model.canSave)
    }

    @Test func orderOptions_fallBackWithoutLabels_andKeepTheCurrentOrder() {
        let fallback = FilteredDeckFormModel.orderOptions(labels: [], including: .random)
        #expect(fallback.map(\.order) == [.random, .added, .due, .oldestSeenFirst])

        let unknown = FilteredDeckOrder(rawValue: 42)
        let kept = FilteredDeckFormModel.orderOptions(labels: Self.labels, including: unknown)
        #expect(kept.last?.order == unknown)
    }
}
