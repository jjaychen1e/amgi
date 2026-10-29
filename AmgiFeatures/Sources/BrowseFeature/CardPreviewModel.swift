//
//  CardPreviewModel.swift
//  BrowseFeature
//
//  Created by Junjie Chen on 29.10.2026.
//

import OSLog
import AppCore
import AmgiCardWeb
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiServices
import Dependencies
import Foundation

/// State and I/O for the card previewer: which of the browse results is on
/// screen, which of its cards, which side, and the engine's render of each
/// card.
///
/// The pager keeps its neighbouring pages alive, so state is keyed by note
/// and card rather than held for "the current" one, and a page that scrolls
/// back into view finds its render already there.
@Observable
@MainActor
final class CardPreviewModel {
    enum Side: Hashable, CaseIterable {
        case front
        case back

        var label: String {
            switch self {
            case .front: "Front"
            case .back: "Back"
            }
        }
    }

    /// One of a note's cards, as the card picker lists it.
    struct Card: Identifiable, Equatable {
        let id: CardID
        let ord: Int
        let label: String
    }

    enum PageState {
        case loading
        case loaded(note: NoteRecord, cards: [Card])
        case failed(String)
    }

    enum RenderState {
        case loading
        case rendered(RenderedCard)
        case failed(String)
    }

    /// The browse results as they were listed when the previewer opened.
    let noteIDs: [NoteID]

    /// Paging to another note shows its front, the way a reviewer would
    /// meet it.
    var index: Int {
        didSet { if index != oldValue { side = .front } }
    }

    var side: Side = .front

    private(set) var pages: [NoteID: PageState] = [:]
    private(set) var renders: [CardID: RenderState] = [:]
    private(set) var selectedCardIDs: [NoteID: CardID] = [:]

    @ObservationIgnored private var notetypes: [NotetypeID: Notetype] = [:]

    @ObservationIgnored @Dependency(\.noteClient) private var noteClient
    @ObservationIgnored @Dependency(\.cardClient) private var cardClient
    @ObservationIgnored @Dependency(\.notetypesClient) private var notetypesClient
    @ObservationIgnored @Dependency(\.cardRenderingService) private var cardRendering

    init(noteIDs: [NoteID], startingAt noteID: NoteID) {
        self.noteIDs = noteIDs
        index = noteIDs.firstIndex(of: noteID) ?? 0
    }

    // MARK: - Derived

    var currentNoteID: NoteID? {
        noteIDs.indices.contains(index) ? noteIDs[index] : nil
    }

    /// The note the Edit button opens; nil until its page has loaded.
    var currentNote: NoteRecord? {
        guard let currentNoteID, case .loaded(let note, _)? = pages[currentNoteID] else { return nil }
        return note
    }

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < noteIDs.count - 1 }

    func page(for noteID: NoteID) -> PageState {
        pages[noteID] ?? .loading
    }

    func selectedCard(for noteID: NoteID) -> Card? {
        guard case .loaded(_, let cards)? = pages[noteID] else { return nil }
        return cards.first { $0.id == selectedCardIDs[noteID] } ?? cards.first
    }

    func renderState(for card: Card) -> RenderState {
        renders[card.id] ?? .loading
    }

    // MARK: - Navigation

    func goBack() {
        if canGoBack { index -= 1 }
    }

    func goForward() {
        if canGoForward { index += 1 }
    }

    /// Switching cards keeps the side, so the backs of a note's cards can
    /// be compared one after another.
    func select(_ card: Card, of noteID: NoteID) async {
        selectedCardIDs[noteID] = card.id
        await render(card.id)
    }

    // MARK: - Loading

    /// Loads a note's cards and renders the selected one. A no-op once the
    /// note has loaded, so a page can call it every time it reappears.
    func load(_ noteID: NoteID) async {
        if case .loaded? = pages[noteID] { return }
        pages[noteID] = .loading
        do {
            guard let note = try await noteClient.fetch(noteID) else {
                pages[noteID] = .failed("This note no longer exists.")
                return
            }
            let records = try await cardClient.fetchByNote(noteID).sorted { $0.ord < $1.ord }
            let notetype = await notetype(note.mid)
            let cards = records.map { record in
                Card(id: record.id, ord: Int(record.ord), label: Self.label(ord: Int(record.ord), notetype: notetype))
            }
            pages[noteID] = .loaded(note: note, cards: cards)
            if let card = selectedCard(for: noteID) {
                selectedCardIDs[noteID] = card.id
                await render(card.id)
            }
        } catch {
            Log.browse.error("Card preview failed to load note \(noteID.rawValue): \(error)")
            pages[noteID] = .failed("This note couldn't be loaded.")
        }
    }

    /// Forgets a note and loads it again, after an edit changed its fields
    /// and possibly which cards it has.
    func reload(_ noteID: NoteID) async {
        if case .loaded(_, let cards)? = pages[noteID] {
            for card in cards { renders[card.id] = nil }
        }
        pages[noteID] = nil
        await load(noteID)
    }

    private func render(_ cardID: CardID) async {
        if case .rendered? = renders[cardID] { return }
        renders[cardID] = .loading
        let cardRendering = cardRendering
        do {
            let rendered = try await backendOffload { try cardRendering.renderCard(cardID) }
            renders[cardID] = .rendered(RenderedCard(
                frontHTML: CardText.strippingTypedAnswerPlaceholders(from: rendered.frontHTML),
                backHTML: CardText.strippingTypedAnswerPlaceholders(from: rendered.backHTML),
                cardCSS: rendered.cardCSS
            ))
        } catch {
            Log.browse.error("Card preview failed to render card \(cardID.rawValue): \(error)")
            renders[cardID] = .failed("This card couldn't be rendered.")
        }
    }

    /// Cached per notetype. A failed fetch only costs the picker its
    /// template names.
    private func notetype(_ id: NotetypeID) async -> Notetype? {
        if let cached = notetypes[id] { return cached }
        let fetched = try? await notetypesClient.get(id)
        notetypes[id] = fetched
        return fetched
    }

    /// The picker's name for a card: its template, or its cloze number on a
    /// cloze notetype, where one template makes every card.
    static func label(ord: Int, notetype: Notetype?) -> String {
        if notetype?.config.kind == .cloze {
            return "Cloze \(ord + 1)"
        }
        guard let templates = notetype?.templates, templates.indices.contains(ord) else {
            return "Card \(ord + 1)"
        }
        return templates[ord].name
    }
}
