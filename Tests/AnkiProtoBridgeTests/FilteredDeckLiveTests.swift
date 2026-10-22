//
//  FilteredDeckLiveTests.swift
//  AnkiProtoBridgeTests
//
//  Created by Junjie Chen on 22.10.2026.
//

import Foundation
import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend
import AnkiProto
private import SwiftProtobuf

/// Creating, studying, emptying and rebuilding a filtered deck against the
/// real Rust backend. CardType: 0 new, 1 learn, 2 review. CardQueue: 0 new,
/// 1 learn, 2 review.
@Suite struct FilteredDeckLiveTests {
    // MARK: - Fixture

    /// Two home decks: English holds three travel cards (review, due in 30
    /// days) and two shopping cards (new); Spanish holds one travel card
    /// (review, due in 30 days) and one new card.
    private struct Fixture {
        let english: DeckID
        let spanish: DeckID
        let englishTravel: [CardID]
        let englishShopping: [CardID]
        let spanishTravel: CardID
        let spanishNew: CardID

        var allTravel: [CardID] { englishTravel + [spanishTravel] }
    }

    private func makeFixture(_ backend: AnkiBackend) throws -> Fixture {
        let english = try backend.invoke(.addDeck(template: try backend.invoke(.newDeck), name: "English")).id
        let spanish = try backend.invoke(.addDeck(template: try backend.invoke(.newDeck), name: "Spanish")).id

        let englishTravel = try ["airport", "hotel", "ticket"].map {
            try addCard(backend, front: $0, deck: english, tags: ["travel"])
        }
        let englishShopping = try ["receipt", "discount"].map {
            try addCard(backend, front: $0, deck: english, tags: ["shopping"])
        }
        let spanishTravel = try addCard(backend, front: "aeropuerto", deck: spanish, tags: ["travel"])
        let spanishNew = try addCard(backend, front: "tienda", deck: spanish, tags: [])

        // Travel cards become reviews that are not due for a month.
        try backend.invoke(.setDueDate(cardIds: englishTravel + [spanishTravel], days: "30"))

        return Fixture(
            english: english,
            spanish: spanish,
            englishTravel: englishTravel,
            englishShopping: englishShopping,
            spanishTravel: spanishTravel,
            spanishNew: spanishNew
        )
    }

    private func addCard(_ backend: AnkiBackend, front: String, deck: DeckID, tags: [String]) throws -> CardID {
        let names = try backend.invoke(.notetypeNames)
        let basic = try #require(names.first { $0.name == "Basic" })
        var template = try backend.invoke(.newNote(notetypeId: basic.id))
        template.fields[0] = front
        template.fields[1] = "back of \(front)"
        template.tags = tags
        try backend.invoke(.addNote(template: template, deckId: deck))
        let noteId = try #require(try backend.invoke(.searchNoteIds(query: "\"front:\(front)\"")).first)
        return try #require(try backend.invoke(.cardIDsOfNote(id: noteId)).first)
    }

    private func createFiltered(
        _ backend: AnkiBackend,
        name: String,
        search: String,
        limit: Int = 100,
        order: FilteredDeckOrder = .random,
        reschedule: Bool = true
    ) throws -> DeckCreation {
        var draft = try backend.invoke(.getOrCreateFilteredDeck(deckId: DeckID(0)))
        draft.name = name
        draft.search = search
        draft.limit = limit
        draft.order = order
        draft.reschedule = reschedule
        return try backend.invoke(.addOrUpdateFilteredDeck(draft))
    }

    /// Answers whatever is at the top of the queue — the backend rejects any
    /// other card — until each card in `ratings` has been answered once.
    private func answerInQueueOrder(_ ratings: [CardID: Rating], _ backend: AnkiBackend) throws {
        var pending = ratings
        for _ in 0..<10 where !pending.isEmpty {
            let queued: QueuedCardsResult = try backend.invoke(.getQueuedCards(fetchLimit: 1))
            let top = try #require(queued.cards.first, "queue ran dry before every card was answered")
            let removed = pending.removeValue(forKey: top.card.id)
            let rating = try #require(removed, "unexpected card at the top")
            try backend.invoke(.answerReviewCard(cardId: top.card.id, rating: rating, timeSpentMs: 1_000, states: top.states))
        }
        #expect(pending.isEmpty)
    }

    private func cardsIn(_ deck: DeckID, of ids: [CardID], _ backend: AnkiBackend) throws -> Set<CardID> {
        Set(try ids.filter { try backend.invoke(.getCard(id: $0)).did == deck })
    }

    private func deckCount(_ backend: AnkiBackend) throws -> Int {
        try backend.invoke(.deckTree(at: Date(timeIntervalSince1970: 0))).flattened().count
    }

    // MARK: - Defaults

    @Test func newDraft_carriesAnkiDefaults_andOrderLabelsCoverEveryOrder() throws {
        try withScratchCollection("filtered-defaults") { backend, _ in
            let draft = try backend.invoke(.getOrCreateFilteredDeck(deckId: DeckID(0)))
            #expect(draft.isNew)
            #expect(!draft.name.isEmpty, "backend names a new deck 'Filtered Deck <time>'")
            #expect(draft.reschedule, "Anki reschedules by default")
            #expect(draft.limit == 100)
            #expect(draft.order == .random)

            let labels = try backend.invoke(.filteredDeckOrderLabels)
            #expect(labels.count == 11)
            #expect(labels[Int(FilteredDeckOrder.random.rawValue)] == "Random")
            #expect(labels[Int(FilteredDeckOrder.added.rawValue)] == "Order added")
            #expect(labels[Int(FilteredDeckOrder.due.rawValue)] == "Order due")
        }
    }

    // MARK: - Search scope

    @Test func tagSearch_collectsCardsThatAreNotYetDue_acrossDecks() throws {
        try withScratchCollection("filtered-tag") { backend, _ in
            let fx = try makeFixture(backend)
            let before = try backend.invoke(.getCard(id: fx.spanishTravel))
            #expect(before.type == 2 && before.ivl == 30, "fixture card is a review due in 30 days")

            let created = try createFiltered(backend, name: "Travel", search: "tag:travel")
            #expect(created.changes.card)

            let all = fx.allTravel + fx.englishShopping + [fx.spanishNew]
            #expect(try cardsIn(created.id, of: all, backend) == Set(fx.allTravel))

            // Same card, same id, with its home deck remembered.
            let moved = try backend.invoke(.getCard(id: fx.spanishTravel))
            #expect(moved.id == before.id)
            #expect(moved.nid == before.nid)
            #expect(moved.odid == fx.spanish)
            #expect(moved.odue == before.due)

            let tree = try backend.invoke(.deckTree(at: Date()))
            #expect(tree.find(created.id)?.isFiltered == true)
            #expect(tree.find(created.id)?.counts.reviewCount == 4, "not-yet-due cards are studyable")
        }
    }

    @Test func deckSearch_restrictsToOneHomeDeck() throws {
        try withScratchCollection("filtered-deck-scope") { backend, _ in
            let fx = try makeFixture(backend)
            let created = try createFiltered(backend, name: "English travel", search: #"deck:"English" tag:travel"#)
            let all = fx.allTravel + fx.englishShopping + [fx.spanishNew]
            #expect(try cardsIn(created.id, of: all, backend) == Set(fx.englishTravel))
        }
    }

    // MARK: - Limit and order

    @Test func limitAndOrder_pickTheExpectedCards() throws {
        try withScratchCollection("filtered-order") { backend, _ in
            let fx = try makeFixture(backend)

            let oldest = try createFiltered(backend, name: "Oldest", search: "tag:travel", limit: 2, order: .added)
            #expect(try cardsIn(oldest.id, of: fx.allTravel, backend) == Set(fx.englishTravel.prefix(2)))
            try backend.invoke(.emptyFilteredDeck(deckId: oldest.id))

            let latestFirst = FilteredDeckOrder(rawValue: 7)
            let newest = try createFiltered(backend, name: "Newest", search: "tag:travel", limit: 2, order: latestFirst)
            #expect(try cardsIn(newest.id, of: fx.allTravel, backend) == [fx.englishTravel[2], fx.spanishTravel])
            try backend.invoke(.emptyFilteredDeck(deckId: newest.id))

            let random = try createFiltered(backend, name: "Random", search: "tag:travel", limit: 3, order: .random)
            #expect(try cardsIn(random.id, of: fx.allTravel, backend).count == 3)

            let saved = try backend.invoke(.getOrCreateFilteredDeck(deckId: newest.id))
            #expect(saved.limit == 2)
            #expect(saved.order == latestFirst)
        }
    }

    // MARK: - Study

    @Test func study_rendersTheCardsOwnTemplateAndCSS() throws {
        try withScratchCollection("filtered-render") { backend, _ in
            let names = try backend.invoke(.notetypeNames)
            let basicId = try #require(names.first { $0.name == "Basic" }).id
            var basic = try backend.invoke(.notetype(for: basicId))
            basic.config.css = ".card { color: rgb(1, 2, 3); } .phrase { font-weight: 700; }"
            basic.templates[0].config.qFormat = #"<div class="phrase">{{Front}}</div>"#
            try backend.invoke(.updateNotetype(basic))

            let fx = try makeFixture(backend)
            let created = try createFiltered(backend, name: "Travel", search: "tag:travel")

            let queued: QueuedCardsResult = try backend.invoke(.getQueuedCards(fetchLimit: 10))
            let first = try #require(queued.cards.first)
            #expect(fx.allTravel.contains(first.card.id))
            #expect(first.card.did == created.id)

            let rendered = try backend.invoke(.renderExistingCard(cardId: first.card.id))
            #expect(rendered.frontHTML.contains(#"class="phrase""#))
            #expect(rendered.cardCSS.contains("rgb(1, 2, 3)"))
        }
    }

    @Test func rescheduleOn_answersUpdateTheRealSchedule() throws {
        try withScratchCollection("filtered-resched-on") { backend, _ in
            let fx = try makeFixture(backend)
            let created = try createFiltered(backend, name: "Mixed", search: "front:aeropuerto or front:receipt", reschedule: true)

            let review = try backend.invoke(.getCard(id: fx.spanishTravel))
            // Easy on the review: a 30-days-early Good would legitimately
            // keep the 30-day interval, so it couldn't show a change.
            try answerInQueueOrder([fx.spanishTravel: .easy, fx.englishShopping[0]: .good], backend)

            let answeredReview = try backend.invoke(.getCard(id: fx.spanishTravel))
            #expect(answeredReview.reps == review.reps + 1)
            #expect(answeredReview.type == 2)
            #expect(answeredReview.ivl > review.ivl, "Easy lengthens the interval")
            #expect(answeredReview.due != review.odue)
            #expect(answeredReview.did == fx.spanish, "a graduated review goes home")

            let answeredNew = try backend.invoke(.getCard(id: fx.englishShopping[0]))
            #expect(answeredNew.type == 1, "a new card enters learning")
            #expect(answeredNew.did == created.id)
            #expect(answeredNew.odid == fx.english)

            try backend.invoke(.emptyFilteredDeck(deckId: created.id))
            let home = try backend.invoke(.getCard(id: fx.englishShopping[0]))
            #expect(home.did == fx.english)
            #expect(home.type == 1, "the learning progress survives emptying")
        }
    }

    @Test func rescheduleOff_previewLeavesTheScheduleUntouched() throws {
        try withScratchCollection("filtered-resched-off") { backend, _ in
            let fx = try makeFixture(backend)
            let reviewBefore = try backend.invoke(.getCard(id: fx.spanishTravel))
            let newBefore = try backend.invoke(.getCard(id: fx.englishShopping[0]))

            let created = try createFiltered(backend, name: "Preview", search: "front:aeropuerto or front:receipt", reschedule: false)
            #expect(try backend.invoke(.getOrCreateFilteredDeck(deckId: created.id)).reschedule == false)

            try answerInQueueOrder([fx.spanishTravel: .easy, fx.englishShopping[0]: .good], backend)

            let review = try backend.invoke(.getCard(id: fx.spanishTravel))
            #expect(review.did == fx.spanish, "Good finishes the preview and returns the card")
            #expect(review.odid == DeckID(0))
            #expect(review.type == reviewBefore.type)
            #expect(review.queue == reviewBefore.queue)
            #expect(review.due == reviewBefore.due)
            #expect(review.ivl == reviewBefore.ivl)

            let new = try backend.invoke(.getCard(id: fx.englishShopping[0]))
            #expect(new.did == fx.english)
            #expect(new.type == 0, "a previewed new card stays new")
            #expect(new.queue == newBefore.queue)
            #expect(new.due == newBefore.due)
        }
    }

    // MARK: - Empty and rebuild

    @Test func empty_returnsCardsHome_keepsTheDeck_andRebuildRecollects() throws {
        try withScratchCollection("filtered-empty-rebuild") { backend, _ in
            let fx = try makeFixture(backend)
            let created = try createFiltered(backend, name: "Travel", search: "tag:travel", limit: 50, order: .due)
            let before = try fx.allTravel.map { try backend.invoke(.getCard(id: $0)) }

            try backend.invoke(.emptyFilteredDeck(deckId: created.id))
            for card in before {
                let home = try backend.invoke(.getCard(id: card.id))
                #expect(home.did == card.odid)
                #expect(home.odid == DeckID(0))
                #expect(home.due == card.odue, "the original due date is restored")
            }
            let kept = try backend.invoke(.getOrCreateFilteredDeck(deckId: created.id))
            #expect(kept.name == "Travel")
            #expect(kept.search == "tag:travel")
            #expect(kept.limit == 50)
            #expect(kept.order == .due)
            #expect(try backend.invoke(.deckTree(at: Date())).find(created.id)?.isFiltered == true)

            #expect(try backend.invoke(.rebuildFilteredDeck(deckId: created.id)) == 4)
            #expect(try cardsIn(created.id, of: fx.allTravel, backend) == Set(fx.allTravel))
        }
    }

    // MARK: - Persistence

    @Test func settingsSurviveClosingAndReopeningTheCollection() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filtered-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func open() throws -> AnkiBackend {
            let backend = try AnkiBackend()
            try backend.openCollection(
                collectionPath: dir.appendingPathComponent("collection.anki2").path,
                mediaFolderPath: dir.appendingPathComponent("media").path,
                mediaDbPath: dir.appendingPathComponent("media.db").path
            )
            return backend
        }

        let first = try open()
        let fx = try makeFixture(first)
        let created = try createFiltered(first, name: "Travel", search: "tag:travel", limit: 3, order: .added, reschedule: false)
        try first.closeCollection()

        let second = try open()
        defer { try? second.closeCollection() }
        let reopened = try second.invoke(.getOrCreateFilteredDeck(deckId: created.id))
        #expect(reopened.name == "Travel")
        #expect(reopened.search == "tag:travel")
        #expect(reopened.limit == 3)
        #expect(reopened.order == .added)
        #expect(reopened.reschedule == false)
        #expect(try cardsIn(created.id, of: fx.allTravel, second).count == 3)
    }

    // MARK: - Failures leave the collection as it was

    @Test func invalidSearch_isRejected_andChangesNothing() throws {
        try withScratchCollection("filtered-invalid") { backend, _ in
            let fx = try makeFixture(backend)
            let decks = try deckCount(backend)

            let error = #expect(throws: BackendError.self) {
                try createFiltered(backend, name: "Broken", search: "(tag:travel")
            }
            #expect(error?.kind == .searchError)
            #expect(try deckCount(backend) == decks)
            for id in fx.allTravel {
                #expect(try backend.invoke(.getCard(id: id)).odid == DeckID(0))
            }
        }
    }

    @Test func zeroMatches_isRejected_andAddsNoDeck() throws {
        try withScratchCollection("filtered-empty-match") { backend, _ in
            _ = try makeFixture(backend)
            let decks = try deckCount(backend)

            let error = #expect(throws: BackendError.self) {
                try createFiltered(backend, name: "Nothing", search: "tag:does-not-exist")
            }
            #expect(error?.kind == .filteredDeckError)
            #expect(try deckCount(backend) == decks)
        }
    }

    @Test func failedEdit_keepsThePreviousSettingsAndCards() throws {
        try withScratchCollection("filtered-failed-edit") { backend, _ in
            let fx = try makeFixture(backend)
            let created = try createFiltered(backend, name: "Travel", search: "tag:travel")

            var draft = try backend.invoke(.getOrCreateFilteredDeck(deckId: created.id))
            draft.search = "tag:does-not-exist"
            #expect(throws: BackendError.self) { try backend.invoke(.addOrUpdateFilteredDeck(draft)) }

            #expect(try backend.invoke(.getOrCreateFilteredDeck(deckId: created.id)).search == "tag:travel")
            #expect(try cardsIn(created.id, of: fx.allTravel, backend) == Set(fx.allTravel))
        }
    }

    @Test func cardsAlreadyInAFilteredDeck_areNotDuplicated() throws {
        try withScratchCollection("filtered-overlap") { backend, _ in
            let fx = try makeFixture(backend)
            let first = try createFiltered(backend, name: "Travel", search: "tag:travel")
            let decks = try deckCount(backend)

            #expect(throws: BackendError.self) {
                try createFiltered(backend, name: "Travel again", search: "tag:travel")
            }
            #expect(try deckCount(backend) == decks)
            #expect(try cardsIn(first.id, of: fx.allTravel, backend) == Set(fx.allTravel))
        }
    }

    @Test func editing_keepsASecondSearchTermTheAppDoesNotShow() throws {
        try withScratchCollection("filtered-second-term") { backend, _ in
            _ = try makeFixture(backend)
            let created = try createFiltered(backend, name: "Travel", search: "tag:travel")

            // Simulate a deck made on desktop with "Enable second filter".
            var proto = try Anki_Decks_FilteredDeckForUpdate(
                serializedBytes: try backend.invoke(.getOrCreateFilteredDeck(deckId: created.id)).base
            )
            var second = Anki_Decks_Deck.Filtered.SearchTerm()
            second.search = "tag:shopping"
            second.limit = 20
            second.order = .due
            proto.config.searchTerms.append(second)
            let withSecond = FilteredDeckDraft(proto, base: try proto.serializedData())
            _ = try backend.invoke(.addOrUpdateFilteredDeck(withSecond))

            var draft = try backend.invoke(.getOrCreateFilteredDeck(deckId: created.id))
            draft.limit = 2
            _ = try backend.invoke(.addOrUpdateFilteredDeck(draft))

            let saved = try Anki_Decks_FilteredDeckForUpdate(
                serializedBytes: try backend.invoke(.getOrCreateFilteredDeck(deckId: created.id)).base
            )
            #expect(saved.config.searchTerms.count == 2)
            #expect(saved.config.searchTerms[0].limit == 2)
            #expect(saved.config.searchTerms[1].search == "tag:shopping")
        }
    }

    // MARK: - Search building

    @Test func appendingSearchTerms_writesQuotedTermsTheBackendAccepts() throws {
        try withScratchCollection("filtered-search-terms") { backend, _ in
            let fx = try makeFixture(backend)

            let oneTag = try backend.invoke(.appendingSearchTerms(.init(kind: .tag, names: ["travel"]), to: ""))
            #expect(oneTag == "tag:travel")

            let anyTag = try backend.invoke(.appendingSearchTerms(.init(kind: .tag, names: ["travel", "shopping"]), to: ""))
            #expect(Set(try backend.invoke(.searchCardIds(query: anyTag))) == Set(fx.allTravel + fx.englishShopping))

            let scoped = try backend.invoke(.appendingSearchTerms(.init(kind: .deck, names: ["English"]), to: oneTag))
            #expect(Set(try backend.invoke(.searchCardIds(query: scoped))) == Set(fx.englishTravel))

            let withoutSpanish = try backend.invoke(
                .appendingSearchTerms(.init(kind: .deck, names: ["Spanish"], excluded: true), to: oneTag)
            )
            #expect(Set(try backend.invoke(.searchCardIds(query: withoutSpanish))) == Set(fx.englishTravel))

            // A name with a space and a quote must come back quoted, and match.
            let odd = try backend.invoke(.addDeck(template: try backend.invoke(.newDeck), name: #"My "Odd" Deck"#)).id
            _ = try addCard(backend, front: "quirk", deck: odd, tags: [])
            let oddSearch = try backend.invoke(.appendingSearchTerms(.init(kind: .deck, names: [#"My "Odd" Deck"#]), to: ""))
            #expect(try backend.invoke(.searchCardIds(query: oddSearch)).count == 1)
        }
    }

    @Test func appendingSearchTerms_rejectsAnInvalidExistingSearch() throws {
        try withScratchCollection("filtered-search-invalid") { backend, _ in
            let error = #expect(throws: BackendError.self) {
                try backend.invoke(.appendingSearchTerms(.init(kind: .tag, names: ["travel"]), to: "(tag:x"))
            }
            #expect(error?.kind == .searchError)
        }
    }

    @Test func deckIdByName_matchesCaseInsensitively_andThrowsNotFound() throws {
        try withScratchCollection("filtered-name-lookup") { backend, _ in
            let fx = try makeFixture(backend)
            #expect(try backend.invoke(.deckIdByName("english")) == fx.english)
            let error = #expect(throws: BackendError.self) { try backend.invoke(.deckIdByName("Nope")) }
            #expect(error?.kind == .notFoundError)
        }
    }
}
