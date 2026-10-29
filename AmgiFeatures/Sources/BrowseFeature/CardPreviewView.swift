//
//  CardPreviewView.swift
//  BrowseFeature
//
//  Created by Junjie Chen on 29.10.2026.
//

import SwiftUI
import AppCore
import AnkiKit
import CardSurface
import Sharing

/// Pushed when a Browse row is tapped: the results one note at a time, each
/// showing a card the way the reviewer draws it. Edit is one tap further, in
/// the toolbar.
///
/// Previous and Next step without a transition. One page stays on screen and
/// its web view swaps the card in place, as the reviewer does between cards;
/// a sliding pager gave every note a fresh web view that drew blank first.
struct CardPreviewView: View {
    @State private var model: CardPreviewModel
    @State private var editingNote: NoteRecord?
    let onNoteChanged: () -> Void

    init(noteIDs: [NoteID], startingAt noteID: NoteID, onNoteChanged: @escaping () -> Void) {
        _model = State(initialValue: CardPreviewModel(noteIDs: noteIDs, startingAt: noteID))
        self.onNoteChanged = onNoteChanged
    }

    var body: some View {
        Group {
            if let noteID = model.currentNoteID {
                CardPreviewPage(model: model, noteID: noteID)
            }
        }
        .task(id: model.index) { await model.loadCurrentAndNeighbours() }
        .navigationTitle("\(model.index + 1) of \(model.noteIDs.count)")
        .navigationBarTitleDisplayMode(.inline)
        // The previewer's own bottom bar would sit under the tab bar.
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar { toolbarContent }
        .navigationDestination(item: $editingNote) { note in
            NoteEditingDestinationView(note: note) {
                Task { await model.reload(note.id) }
                onNoteChanged()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Edit") { editingNote = model.currentNote }
                .disabled(model.currentNote == nil)
                .keyboardShortcut("e", modifiers: .command)
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                model.goBack()
            } label: {
                Label("Previous Note", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .keyboardShortcut(.leftArrow, modifiers: [])
        }
        ToolbarItem(placement: .bottomBar) { Spacer() }
        // The segmented control draws its own capsule; the bar's glass
        // behind it read as a second control stacked under the first.
        if #available(iOS 26, macOS 26, *) {
            ToolbarItem(placement: .bottomBar) { sidePicker }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .bottomBar) { sidePicker }
        }
        ToolbarItem(placement: .bottomBar) { Spacer() }
        ToolbarItem(placement: .bottomBar) {
            Button {
                model.goForward()
            } label: {
                Label("Next Note", systemImage: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private var sidePicker: some View {
        Picker("Side", selection: $model.side) {
            ForEach(CardPreviewModel.Side.allCases, id: \.self) { side in
                Text(side.label).tag(side)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

// MARK: - CardPreviewPage

/// The note on screen: a picker over its cards when it has more than one,
/// above the selected card on the chosen side.
///
/// The view keeps its identity from note to note, so the `CardWebView`
/// below is the same web view throughout and only its card changes.
private struct CardPreviewPage: View {
    let model: CardPreviewModel
    let noteID: NoteID

    @Shared(.appStorage(ReviewPreferences.Keys.cardContentAlignment))
    private var cardContentAlignment: String = CardWebViewContentAlignment.center.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.openLinksExternally))
    private var openLinksExternally: Bool = true

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.page(for: noteID) {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
        case .loaded(_, let cards):
            VStack(spacing: 0) {
                if cards.count > 1 {
                    cardPicker(cards)
                }
                if let card = model.selectedCard(for: noteID) {
                    cardContent(card)
                } else {
                    ContentUnavailableView("This note has no cards.", systemImage: "rectangle.slash")
                }
            }
        }
    }

    private func cardPicker(_ cards: [CardPreviewModel.Card]) -> some View {
        let selectedID = model.selectedCard(for: noteID)?.id
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(cards) { card in
                    BrowseChip(label: card.label, isSelected: card.id == selectedID, small: true) {
                        Task { await model.select(card, of: noteID) }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func cardContent(_ card: CardPreviewModel.Card) -> some View {
        switch model.renderState(for: card) {
        case .loading:
            ProgressView()
                .frame(maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
        case .rendered(let rendered):
            let isBack = model.side == .back
            let html = isBack ? rendered.backHTML : rendered.frontHTML
            if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("This side of the card is empty.", systemImage: "rectangle.slash")
            } else {
                CardWebView(
                    html: html,
                    cardCSS: rendered.cardCSS,
                    autoplayEnabled: false,
                    isAnswerSide: isBack,
                    cardOrdinal: UInt32(card.ord),
                    openLinksExternally: openLinksExternally,
                    contentAlignment: CardWebViewContentAlignment(rawValue: cardContentAlignment) ?? .center,
                    // A template that drives its own answer flow asks for
                    // the back with pycmd('ans').
                    onShowAnswerRequested: { model.side = .back }
                )
            }
        }
    }
}
