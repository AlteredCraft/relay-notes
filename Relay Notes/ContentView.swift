//
//  ContentView.swift
//  Relay Notes
//
//  Created by Sam Keen on 6/8/26.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: RecorderViewModel?
    @State private var reTranscriber: ReTranscriber?
    @State private var cleaner: Cleaner?
    @State private var stores = ModelStores()
    @State private var showSettings = false
    @State private var searchText = ""

    /// True when a non-empty search filter is hiding non-matching notes — the
    /// condition that makes a freshly recorded note look unsaved (GH #6).
    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NotesListView(
                    searchText: searchText,
                    reTranscriber: reTranscriber,
                    cleaner: cleaner,
                    onOpenSettings: { showSettings = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if let viewModel {
                    // A new note whose transcript doesn't match an active filter
                    // would be hidden from the list, looking like it failed to
                    // save — so block starting a recording while filtering (GH #6).
                    RecorderView(viewModel: viewModel, searchActive: isFiltering)
                        .padding(.vertical, 16)
                }
            }
            .navigationTitle("Relay Notes")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search transcripts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Tuning")
                }
            }
            .sheet(isPresented: $showSettings) {
                if let viewModel {
                    SettingsView(tunings: viewModel.tunings, stores: stores)
                }
            }
        }
        .task {
            if viewModel == nil {
                // A persisted engine choice can outlive the model it needs (deleted
                // last session, or never downloaded). Reconcile before first record
                // so we never start an on-device session with no model on disk.
                let tunings = Tunings()
                tunings.reconcileEngineAvailability(readyEngines: stores.readyEngines)
                // One factory shared by the recorder and the re-transcriber so a
                // re-run reuses the already-loaded model rather than a second copy.
                let factory = TranscriberFactory(stores: stores)
                viewModel = RecorderViewModel(
                    engine: LiveAudioEngine(),
                    transcriberFactory: factory,
                    modelContext: modelContext,
                    tunings: tunings
                )
                reTranscriber = ReTranscriber(factory: factory, stores: stores)
                // Read personalization live at clean time off the shared `tunings`,
                // so Tuning-sheet edits apply on the next "Clean up" with no rewiring.
                cleaner = Cleaner(
                    store: stores.cleanup,
                    personalization: { tunings.cleanupPersonalization }
                )
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Note.self, inMemory: true)
}
