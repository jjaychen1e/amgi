//
//  FilteredDeckSaveTests.swift
//  AnkiServicesTests
//
//  Created by Junjie Chen on 22.10.2026.
//

import Foundation
import Testing
import AnkiKit
import AnkiBackend
import AnkiProtoBridge
@testable import AnkiServices

/// The checks `DecksService.saveFilteredDeck` runs before the backend sees
/// the draft, against a scratch collection.
@Suite struct FilteredDeckSaveTests {
    private func withCollection(_ body: (AnkiBackend) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filtered-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = try AnkiBackend()
        try backend.openCollection(
            collectionPath: dir.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: dir.appendingPathComponent("media").path,
            mediaDbPath: dir.appendingPathComponent("media.db").path
        )
        defer { try? backend.closeCollection() }

        let names = try backend.invoke(.notetypeNames)
        let basic = try #require(names.first { $0.name == "Basic" })
        var note = try backend.invoke(.newNote(notetypeId: basic.id))
        note.fields[0] = "airport"
        note.fields[1] = "back"
        note.tags = ["travel"]
        let english = try backend.invoke(.addDeck(template: try backend.invoke(.newDeck), name: "English")).id
        try backend.invoke(.addNote(template: note, deckId: english))

        try body(backend)
    }

    private func draft(_ backend: AnkiBackend, name: String, search: String = "tag:travel") throws -> FilteredDeckDraft {
        var draft = try backend.invoke(.getOrCreateFilteredDeck(deckId: DeckID(0)))
        draft.name = name
        draft.search = search
        return draft
    }

    private func deckNames(_ backend: AnkiBackend) throws -> [String] {
        try backend.invoke(.deckTree(at: Date(timeIntervalSince1970: 0))).flattened().map(\.name)
    }

    @Test func blankName_isRejected() throws {
        try withCollection { backend in
            let before = try deckNames(backend)
            let error = #expect(throws: BackendError.self) {
                try persistFilteredDeck(try draft(backend, name: "   "), backend: backend)
            }
            #expect(error?.kind == .invalidInput)
            #expect(try deckNames(backend) == before)
        }
    }

    @Test func nonPositiveLimit_isRejected() throws {
        try withCollection { backend in
            var zero = try draft(backend, name: "Travel")
            zero.limit = 0
            let error = #expect(throws: BackendError.self) { try persistFilteredDeck(zero, backend: backend) }
            #expect(error?.kind == .invalidInput)
        }
    }

    @Test func nameOfAnotherDeck_isRejected_caseInsensitively() throws {
        try withCollection { backend in
            let before = try deckNames(backend)
            let error = #expect(throws: BackendError.self) {
                try persistFilteredDeck(try draft(backend, name: "english"), backend: backend)
            }
            #expect(error?.kind == .exists)
            #expect(try deckNames(backend) == before, "no 'english+' deck appears")
        }
    }

    @Test func trimmedName_isSaved_andTheDeckMayKeepItsOwnName() throws {
        try withCollection { backend in
            let created = try persistFilteredDeck(try draft(backend, name: "  Travel  "), backend: backend)
            #expect(try deckNames(backend).contains("Travel"))

            var edit = try backend.invoke(.getOrCreateFilteredDeck(deckId: created.id))
            #expect(edit.name == "Travel")
            edit.reschedule = false
            let saved = try persistFilteredDeck(edit, backend: backend)
            #expect(saved.id == created.id)
            #expect(try backend.invoke(.getOrCreateFilteredDeck(deckId: created.id)).reschedule == false)

            let clash = #expect(throws: BackendError.self) {
                try persistFilteredDeck(try draft(backend, name: "TRAVEL", search: "tag:travel"), backend: backend)
            }
            #expect(clash?.kind == .exists)
        }
    }
}
