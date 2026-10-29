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
import Theme

/// Pushed when a Browse row is tapped: one page per note in the results,
/// swiped through like a deck, each showing a card the way the reviewer
/// draws it. Edit is one tap further, in the toolbar.
struct CardPreviewView: View {
    @State private var model: CardPreviewModel
    @State private var editingNote: NoteRecord?
    let onNoteChanged: () -> Void

    init(noteIDs: [NoteID], startingAt noteID: NoteID, onNoteChanged: @escaping () -> Void) {
        _model = State(initialValue: CardPreviewModel(noteIDs: noteIDs, startingAt: noteID))
        self.onNoteChanged = onNoteChanged
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.index) {
            ForEach(model.noteIDs.indices, id: \.self) { index in
                CardPreviewPage(model: model, noteID: model.noteIDs[index])
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .navigationTitle("\(model.index + 1) of \(model.noteIDs.count)")
        .navigationBarTitleDisplayMode(.inline)
        // The pager's own bottom bar would sit under the tab bar.
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
                withAnimation(AmgiMotion.standard) { model.goBack() }
            } label: {
                Label("Previous Note", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .keyboardShortcut(.leftArrow, modifiers: [])
        }
        ToolbarItem(placement: .bottomBar) { Spacer() }
        ToolbarItem(placement: .bottomBar) {
            Picker("Side", selection: $model.side) {
                ForEach(CardPreviewModel.Side.allCases, id: \.self) { side in
                    Text(side.label).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItem(placement: .bottomBar) { Spacer() }
        ToolbarItem(placement: .bottomBar) {
            Button {
                withAnimation(AmgiMotion.standard) { model.goForward() }
            } label: {
                Label("Next Note", systemImage: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }
}

// MARK: - CardPreviewPage

/// One note in the pager: a picker over its cards when it has more than
/// one, above the selected card on the chosen side.
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
            .task(id: noteID) { await model.load(noteID) }
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
