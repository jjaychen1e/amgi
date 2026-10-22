//
//  UITestFixtureGenerator.swift
//  AnkiProtoBridgeTests
//
//  Verification branch only. Writes the collection the filtered-deck UI test
//  runs against to $AMGI_FIXTURE_OUT; skipped when the variable is unset.
//

import Foundation
import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

@Suite struct UITestFixtureGenerator {
    static let outputDirectory = ProcessInfo.processInfo.environment["AMGI_FIXTURE_OUT"]

    @Test(.enabled(if: outputDirectory != nil))
    func generate() throws {
        let dir = URL(fileURLWithPath: try #require(Self.outputDirectory))
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let backend = try AnkiBackend()
        try backend.openCollection(
            collectionPath: dir.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: dir.appendingPathComponent("media").path,
            mediaDbPath: dir.appendingPathComponent("media.db").path
        )

        // A user-styled note type: custom HTML and CSS the review must keep.
        let names = try backend.invoke(.notetypeNames)
        let basicId = try #require(names.first { $0.name == "Basic" }).id
        var basic = try backend.invoke(.notetype(for: basicId))
        basic.config.css = """
        .card { font-family: Georgia, serif; font-size: 22px; text-align: center; \
        color: #073642; background-color: #fdf6e3; }
        .phrase { display: inline-block; padding: 16px 28px; border: 4px solid #268bd2; \
        border-radius: 14px; color: #b58900; font-size: 40px; font-weight: 700; }
        .badge { margin-top: 12px; color: #d33682; font-size: 16px; letter-spacing: 2px; }
        .answer { color: #2aa198; font-size: 30px; }
        """
        basic.templates[0].config.qFormat = #"<div class="phrase">{{Front}}</div><div class="badge">CUSTOM TEMPLATE</div>"#
        basic.templates[0].config.aFormat = #"{{FrontSide}}<hr id=answer><div class="answer">{{Back}}</div>"#
        try backend.invoke(.updateNotetype(basic))

        let english = try backend.invoke(.addDeck(template: try backend.invoke(.newDeck), name: "English")).id
        let spanish = try backend.invoke(.addDeck(template: try backend.invoke(.newDeck), name: "Spanish")).id

        func add(_ front: String, _ back: String, _ deck: DeckID, _ tags: [String]) throws -> CardID {
            var note = try backend.invoke(.newNote(notetypeId: basicId))
            note.fields[0] = front
            note.fields[1] = back
            note.tags = tags
            try backend.invoke(.addNote(template: note, deckId: deck))
            let nid = try #require(try backend.invoke(.searchNoteIds(query: "\"front:\(front)\"")).first)
            return try #require(try backend.invoke(.cardIDsOfNote(id: nid)).first)
        }

        let travel = [
            try add("airport", "the place planes leave from", english, ["travel"]),
            try add("boarding pass", "the ticket you show at the gate", english, ["travel"]),
            try add("luggage", "bags you travel with", english, ["travel"]),
            try add("aeropuerto", "airport", spanish, ["travel"]),
        ]
        _ = try add("receipt", "proof of purchase", english, ["shopping"])
        _ = try add("discount", "a lower price", english, ["shopping"])
        _ = try add("tienda", "shop", spanish, [])

        // Travel cards are reviews that are not due for a month.
        try backend.invoke(.setDueDate(cardIds: travel, days: "30"))
        try backend.invoke(.setCurrentDeck(deckId: english))
        try backend.closeCollection()
    }
}
