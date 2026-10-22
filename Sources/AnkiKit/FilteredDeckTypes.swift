//
//  FilteredDeckTypes.swift
//  AnkiKit
//
//  Created by Junjie Chen on 22.10.2026.
//

package import Foundation

/// One of the backend's filtered-deck card orders. Raw values mirror
/// `Deck.Filtered.SearchTerm.Order`; the human labels come from the
/// backend (`Request.filteredDeckOrderLabels`), indexed by raw value.
public struct FilteredDeckOrder: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let oldestSeenFirst = Self(rawValue: 0)
    public static let random = Self(rawValue: 1)
    public static let added = Self(rawValue: 5)
    public static let due = Self(rawValue: 6)
}

/// The editable part of a filtered deck — Anki's `FilteredDeckForUpdate`.
///
/// Only the first search term is surfaced. `base` carries the backend's
/// message opaquely so everything the app does not edit (a second search
/// term, preview delays) survives the round-trip untouched.
public struct FilteredDeckDraft: Sendable, Equatable {
    /// Zero for a deck that has not been added yet.
    public let id: DeckID
    public var name: String
    public var search: String
    public var limit: Int
    public var order: FilteredDeckOrder
    /// Anki's "Reschedule cards based on my answers in this deck". Off
    /// means preview mode: answers leave the card's real schedule alone.
    public var reschedule: Bool
    package let base: Data

    public var isNew: Bool { id.rawValue == 0 }

    package init(
        id: DeckID,
        name: String,
        search: String,
        limit: Int,
        order: FilteredDeckOrder,
        reschedule: Bool,
        base: Data
    ) {
        self.id = id
        self.name = name
        self.search = search
        self.limit = limit
        self.order = order
        self.reschedule = reschedule
        self.base = base
    }
}

/// Tags or decks picked in the filtered-deck form, turned into search terms
/// by the backend, which knows Anki's quoting and escaping rules.
public struct SearchTermSelection: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case tag
        case deck
    }

    public var kind: Kind
    /// Full names: `travel::airport`, `English::Verbs`.
    public var names: [String]
    /// Included names match any of them (`tag:a OR tag:b`); excluded names
    /// must all be absent (`-tag:a -tag:b`).
    public var excluded: Bool

    public init(kind: Kind, names: [String], excluded: Bool = false) {
        self.kind = kind
        self.names = names
        self.excluded = excluded
    }
}
