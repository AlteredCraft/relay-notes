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
                    SettingsView(tunings: viewModel.tunings)
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = RecorderViewModel(
                    engine: LiveAudioEngine(),
                    transcriberFactory: TranscriberFactory(),
                    modelContext: modelContext,
                    tunings: Tunings()
                )
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Note.self, inMemory: true)
}
