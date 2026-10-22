//
//  FilteredDeckRequests.swift
//  AnkiProtoBridge
//
//  Created by Junjie Chen on 22.10.2026.
//

public import AnkiBackend
public import AnkiKit
package import AnkiProto
package import Foundation
import SwiftProtobuf

// Creating and editing filtered decks. Rebuild and empty are scheduler
// methods and live in `SchedulerRequests.swift`.

extension Request where Response == FilteredDeckDraft {
    /// Reads an existing filtered deck's settings, or — for id 0 — the
    /// backend's defaults for a new one (not yet added to the collection).
    public static func getOrCreateFilteredDeck(deckId: DeckID) -> Self {
        Self(
            serviceId: ServiceID.decks,
            methodId: DecksMethod.getOrCreateFilteredDeck,
            encode: {
                var proto = Anki_Decks_DeckId()
                proto.did = deckId.rawValue
                return try proto.serializedData()
            },
            decode: { bytes in
                let proto = try Anki_Decks_FilteredDeckForUpdate(serializedBytes: bytes)
                return FilteredDeckDraft(proto, base: bytes)
            }
        )
    }
}

extension Request where Response == DeckCreation {
    /// Adds (id 0) or updates a filtered deck, then rebuilds it — one
    /// undoable backend transaction. An invalid search, or one that
    /// matches no cards, fails the call and rolls the whole change back.
    public static func addOrUpdateFilteredDeck(_ draft: FilteredDeckDraft) -> Self {
        Self(
            serviceId: ServiceID.decks,
            methodId: DecksMethod.addOrUpdateFilteredDeck,
            encode: {
                try Anki_Decks_FilteredDeckForUpdate(draft).serializedData()
            },
            decode: { bytes in
                let resp = try Anki_Collection_OpChangesWithId(serializedBytes: bytes)
                return DeckCreation(id: DeckID(resp.id), changes: CollectionChanges(resp.changes))
            }
        )
    }
}

extension Request where Response == [String] {
    /// The backend's localized labels for every filtered-deck order,
    /// indexed by `FilteredDeckOrder.rawValue`.
    public static var filteredDeckOrderLabels: Self {
        .empty(
            serviceId: ServiceID.decks,
            methodId: DecksMethod.filteredDeckOrderLabels,
            decode: { bytes in try Anki_Generic_StringList(serializedBytes: bytes).vals }
        )
    }
}

extension Request where Response == DeckID {
    /// Looks a deck up by its full name, with the backend's own name
    /// matching (case-insensitive). Throws `.notFoundError` when no deck
    /// has that name.
    public static func deckIdByName(_ name: String) -> Self {
        Self(
            serviceId: ServiceID.decks,
            methodId: DecksMethod.getDeckIdByName,
            encode: {
                var proto = Anki_Generic_String()
                proto.val = name
                return try proto.serializedData()
            },
            decode: { bytes in DeckID(try Anki_Decks_DeckId(serializedBytes: bytes).did) }
        )
    }
}

// MARK: - Conversions

extension FilteredDeckDraft {
    package init(_ proto: Anki_Decks_FilteredDeckForUpdate, base: Data) {
        let term = proto.config.searchTerms.first
        self.init(
            id: DeckID(proto.id),
            name: proto.name,
            search: term?.search ?? "",
            limit: Int(term?.limit ?? 100),
            order: FilteredDeckOrder(rawValue: Int32(term?.order.rawValue ?? 1)),
            reschedule: proto.config.reschedule,
            base: base
        )
    }
}

extension Anki_Decks_FilteredDeckForUpdate {
    /// Applies the draft's edits on top of the message it was read from.
    ///
    /// A new deck gets exactly one search term: the backend's template
    /// pre-fills a second, "<current deck> is:new" one, which desktop Anki
    /// also drops unless "Enable second filter" is ticked. An existing deck
    /// keeps any second term it already had.
    package init(_ draft: FilteredDeckDraft) throws {
        self = try Anki_Decks_FilteredDeckForUpdate(serializedBytes: draft.base)
        id = draft.id.rawValue
        name = draft.name
        allowEmpty = false

        var term = Anki_Decks_Deck.Filtered.SearchTerm()
        term.search = draft.search
        term.limit = UInt32(clamping: draft.limit)
        term.order = Anki_Decks_Deck.Filtered.SearchTerm.Order(rawValue: Int(draft.order.rawValue)) ?? .random

        if draft.isNew || config.searchTerms.isEmpty {
            config.searchTerms = [term]
        } else {
            config.searchTerms[0] = term
        }
        config.reschedule = draft.reschedule
    }
}
