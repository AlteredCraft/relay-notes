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
    @State private var whisperStore = WhisperModelStore()
    @State private var showSettings = false
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NotesListView(searchText: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if let viewModel {
                    RecorderView(viewModel: viewModel)
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
                    SettingsView(tunings: viewModel.tunings, whisperStore: whisperStore)
                }
            }
        }
        .task {
            if viewModel == nil {
                // A persisted `.whisperMLX` engine choice can outlive the model
                // it needs (deleted last session, or never downloaded). Reconcile
                // before first record so we never start a Whisper session with no
                // model on disk.
                let tunings = Tunings()
                tunings.reconcileEngineAvailability(whisperReady: whisperStore.status == .ready)
                viewModel = RecorderViewModel(
                    engine: LiveAudioEngine(),
                    transcriberFactory: TranscriberFactory(whisperModelStore: whisperStore),
                    modelContext: modelContext,
                    tunings: tunings
                )
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Note.self, inMemory: true)
}
