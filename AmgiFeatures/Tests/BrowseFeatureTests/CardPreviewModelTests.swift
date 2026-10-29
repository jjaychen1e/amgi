//
//  CardPreviewModelTests.swift
//  BrowseFeatureTests
//
//  Created by Junjie Chen on 29.10.2026.
//

import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Testing
import Foundation
@testable import BrowseFeature

@Suite("CardPreviewModel")
@MainActor
struct CardPreviewModelTests {

    private nonisolated static func note(_ id: Int64, mid: Int64 = 1) -> NoteRecord {
        NoteRecord(id: NoteID(id), guid: "g\(id)", mid: NotetypeID(mid), mod: 0, flds: "", sfld: "", csum: 0)
    }

    private nonisolated static func card(_ id: Int64, note: Int64, ord: Int32) -> CardRecord {
        CardRecord(id: CardID(id), nid: NoteID(note), did: DeckID(1), ord: ord, mod: 0)
    }

    private nonisolated static let basicAndReversed = Notetype(
        id: NotetypeID(1),
        templates: [.init(name: "Card 1"), .init(name: "Reverse")]
    )

    /// Records which cards were rendered, across the backend hop.
    private final class RenderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [CardID] = []

        func record(_ id: CardID) {
            lock.lock()
            defer { lock.unlock() }
            ids.append(id)
        }

        var all: [CardID] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    /// Two notes: note 1 has two cards, served out of ord order; note 2 has one.
    private func withCollection(
        notes: [Int64] = [1, 2],
        notetype: Notetype = basicAndReversed,
        log: RenderLog = RenderLog(),
        render: @escaping @Sendable (CardID) throws -> RenderedCard = { id in
            RenderedCard(frontHTML: "front \(id.rawValue)", backHTML: "back \(id.rawValue)", cardCSS: ".card {}")
        },
        operation: () async -> Void
    ) async {
        await withDependencies {
            $0.noteClient.fetch = { id in notes.contains(id.rawValue) ? Self.note(id.rawValue) : nil }
            $0.cardClient.fetchByNote = { id in
                id.rawValue == 1
                    ? [Self.card(11, note: 1, ord: 1), Self.card(10, note: 1, ord: 0)]
                    : [Self.card(20, note: id.rawValue, ord: 0)]
            }
            $0.notetypesClient.get = { _ in notetype }
            $0.cardRenderingService.renderCard = { id in
                log.record(id)
                return try render(id)
            }
        } operation: {
            await operation()
        }
    }

    // MARK: Labels

    @Test("cards are named after their template, or their cloze number")
    func labels() {
        #expect(CardPreviewModel.label(ord: 1, notetype: Self.basicAndReversed) == "Reverse")

        var cloze = Self.basicAndReversed
        cloze.config.kind = .cloze
        #expect(CardPreviewModel.label(ord: 2, notetype: cloze) == "Cloze 3")

        #expect(CardPreviewModel.label(ord: 5, notetype: Self.basicAndReversed) == "Card 6")
        #expect(CardPreviewModel.label(ord: 0, notetype: nil) == "Card 1")
    }

    // MARK: Loading

    @Test("loading a note lists its cards in ord order and renders the first")
    func loadRendersFirstCard() async {
        let log = RenderLog()
        await withCollection(log: log) {
            let model = CardPreviewModel(noteIDs: [NoteID(1), NoteID(2)], startingAt: NoteID(1))
            await model.load(NoteID(1))

            guard case .loaded(let note, let cards) = model.page(for: NoteID(1)) else {
                Issue.record("expected note 1 to load")
                return
            }
            #expect(note.id == NoteID(1))
            #expect(cards.map(\.label) == ["Card 1", "Reverse"])
            #expect(model.selectedCard(for: NoteID(1))?.id == CardID(10))
            #expect(log.all == [CardID(10)])
            #expect(model.currentNote?.id == NoteID(1))
        }
    }

    @Test("typed-answer placeholders are dropped from both sides")
    func stripsTypedAnswerPlaceholders() async {
        await withCollection(render: { _ in
            RenderedCard(frontHTML: "Q[[type:Back]]", backHTML: "Q<hr id=answer>A[[type:Back]]", cardCSS: "")
        }) {
            let model = CardPreviewModel(noteIDs: [NoteID(2)], startingAt: NoteID(2))
            await model.load(NoteID(2))

            let card = model.selectedCard(for: NoteID(2))
            guard let card, case .rendered(let rendered) = model.renderState(for: card) else {
                Issue.record("expected card 20 to render")
                return
            }
            #expect(rendered.frontHTML == "Q")
            #expect(rendered.backHTML == "Q<hr id=answer>A")
        }
    }

    @Test("a note that's gone shows as failed, with nothing to edit")
    func missingNoteFails() async {
        await withCollection(notes: [2]) {
            let model = CardPreviewModel(noteIDs: [NoteID(1)], startingAt: NoteID(1))
            await model.load(NoteID(1))

            guard case .failed = model.page(for: NoteID(1)) else {
                Issue.record("expected a missing note to fail")
                return
            }
            #expect(model.currentNote == nil)
        }
    }

    @Test("a card the engine can't render fails on its own")
    func renderFailure() async {
        struct RenderError: Error {}
        await withCollection(render: { _ in throw RenderError() }) {
            let model = CardPreviewModel(noteIDs: [NoteID(2)], startingAt: NoteID(2))
            await model.load(NoteID(2))

            guard case .loaded = model.page(for: NoteID(2)),
                  let card = model.selectedCard(for: NoteID(2)),
                  case .failed = model.renderState(for: card) else {
                Issue.record("expected the note to load and its card to fail")
                return
            }
        }
    }

    @Test("a loaded note is not fetched or rendered again")
    func loadIsIdempotent() async {
        let log = RenderLog()
        await withCollection(log: log) {
            let model = CardPreviewModel(noteIDs: [NoteID(1)], startingAt: NoteID(1))
            await model.load(NoteID(1))
            await model.load(NoteID(1))
            #expect(log.all == [CardID(10)])
        }
    }

    @Test("reload renders the note again after an edit")
    func reloadRendersAgain() async {
        let log = RenderLog()
        await withCollection(log: log) {
            let model = CardPreviewModel(noteIDs: [NoteID(1)], startingAt: NoteID(1))
            await model.load(NoteID(1))
            await model.reload(NoteID(1))
            #expect(log.all == [CardID(10), CardID(10)])
        }
    }

    // MARK: Cards and sides

    @Test("picking another card renders it and keeps the side")
    func selectingACardKeepsSide() async {
        let log = RenderLog()
        await withCollection(log: log) {
            let model = CardPreviewModel(noteIDs: [NoteID(1)], startingAt: NoteID(1))
            await model.load(NoteID(1))
            model.side = .back

            guard case .loaded(_, let cards) = model.page(for: NoteID(1)) else {
                Issue.record("expected note 1 to load")
                return
            }
            await model.select(cards[1], of: NoteID(1))

            #expect(model.selectedCard(for: NoteID(1))?.id == CardID(11))
            #expect(log.all == [CardID(10), CardID(11)])
            #expect(model.side == .back)
        }
    }

    // MARK: Paging

    @Test("opens on the tapped note")
    func opensOnTappedNote() {
        let model = CardPreviewModel(noteIDs: [NoteID(1), NoteID(2), NoteID(3)], startingAt: NoteID(3))
        #expect(model.index == 2)
        #expect(model.currentNoteID == NoteID(3))
    }

    @Test("paging moves within the results and turns the card to its front")
    func pagingResetsSide() {
        let model = CardPreviewModel(noteIDs: [NoteID(1), NoteID(2)], startingAt: NoteID(1))
        #expect(!model.canGoBack)

        model.side = .back
        model.goForward()
        #expect(model.index == 1)
        #expect(model.side == .front)
        #expect(!model.canGoForward)

        model.goForward()
        #expect(model.index == 1)

        model.goBack()
        #expect(model.index == 0)
    }
}
