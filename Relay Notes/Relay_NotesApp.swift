//
//  Relay_NotesApp.swift
//  Relay Notes
//
//  Created by Sam Keen on 6/8/26.
//

import SwiftData
import SwiftUI

@main
struct Relay_NotesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Note.self)
    }
}
