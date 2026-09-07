import SwiftUI
import StoreKit

struct NotesListView: View {
    @Environment(NoteStore.self) private var store
    @State private var showRecorder = false
    @State private var showInfo = false
    @State private var showModels = false
    @ObservedObject private var models = ModelManager.shared

    // Search
    @State private var searchText: String = ""

#if canImport(UIKit)
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var showUpgrade = false
#endif

    // Computed list after search filter
    private var filteredNotes: [Note] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return store.notes
        }
        return store.notes.filter {
            $0.transcript.localizedCaseInsensitiveContains(searchText)
            || ($0.cards?.contains { $0.term.localizedCaseInsensitiveContains(searchText) || $0.definition.localizedCaseInsensitiveContains(searchText) } ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            let notes = filteredNotes
            Group {
                if store.notes.isEmpty {
                    ContentUnavailableView(label: {
                        Label("Пока пусто", systemImage: "mic")
                    }, description: {
                        Text("Нажмите запись — новая сессия, термин на русском.")
                    })
                } else {
                    List {
                        ForEach(notes) { note in
                            NavigationLink(value: note.id) {
                                NoteRow(note: note)
                            }
                            // Swipe *right* (edge: .leading) to share. Keep default Delete on trailing side.
#if canImport(UIKit)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    share(note: note)
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
#endif
                        }
                        .onDelete(perform: store.delete)
                    }
                }
            }
            .navigationTitle("Дикта")
            .safeAreaInset(edge: .bottom) {
                RecordButton(isRecording: false) {
                    if !models.asrReady {
                        showModels = true
                    } else if WhisperStateManager.shared.canAcceptNewJob() {
                        showRecorder = true
                    } else {
                        Foundation.NSLog("NotesListView: Whisper busy.")
                    }
                }
                .padding(.bottom, 40)
            }
            .navigationDestination(for: UUID.self) { id in
                if let note = store[id] {
                    NoteDetailView(note: note)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showModels = true
                    } label: {
                        Image(systemName: "externaldrive.badge.icloud")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { showModels || !models.asrReady },
                set: { if !$0 { showModels = false } }
            )) {
                ModelSetupView(canDismiss: models.asrReady)
            }
            .searchable(text: $searchText, placement: .automatic, prompt: "Поиск")
            .sheet(isPresented: $showInfo) {
                InfoSheet()
            }
            .sheet(isPresented: $showRecorder) {
                RecorderSheet()
            }
#if canImport(UIKit)
            .sheet(isPresented: $showShareSheet, onDismiss: cleanupTempFile) {
                ShareSheet(shareItems)
            }
            .sheet(isPresented: $showUpgrade) {
                UpgradeSheet().environment(PurchaseManager.shared)
            }
#endif
        }
    }

#if canImport(UIKit)
    // MARK: – Share helpers

    private func share(note: Note) {
        guard PurchaseManager.shared.allowExport() else {
            #if canImport(UIKit)
            showUpgrade = true
            #endif
            return
        }
        do {
            let (body, url) = try TranscriptSharing.makeItems(for: note)
            shareItems = [body, url]
            showShareSheet = true
        } catch {
            print("Failed to prepare share items: \(error)")
        }
    }

    private func cleanupTempFile() {
        if let url = shareItems.first(where: { $0 is URL }) as? URL {
            try? FileManager.default.removeItem(at: url)
        }
        shareItems = []
    }
#endif
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading) {
            Text(note.cards?.first?.term ?? (note.transcript.isEmpty ? "(нет текста)" : String(note.transcript.prefix(40))))
                .font(.headline)
                .lineLimit(1)
            if let def = note.cards?.first?.definition {
                Text(def)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text(note.createdAt.formatted(.dateTime.year().month().day().hour().minute()))
                Spacer()
                Text(note.duration.mmSS)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    let store = NoteStore()
    return NotesListView()
        .environment(store)
}
