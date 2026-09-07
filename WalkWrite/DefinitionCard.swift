import Foundation
import SwiftUI

public struct DefinitionCard: Codable, Hashable, Sendable {
    public var term: String
    public var definition: String
    public var notes: [String]
    public var source: String?

    public init(term: String, definition: String, notes: [String] = [], source: String? = nil) {
        self.term = term
        self.definition = definition
        self.notes = notes
        self.source = source
    }
}

public struct BrainResponse: Codable, Sendable {
    public var cards: [DefinitionCard]
    public var model: String?
    public var searched: Bool?
    public var locale: String?
}

struct DefinitionCardView: View {
    let card: DefinitionCard
    var brain: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.term)
                .font(.title2.bold())
            Text(card.definition)
                .font(.body)
            ForEach(card.notes, id: \.self) { note in
                Text("• \(note)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let source = card.source, let url = URL(string: source) {
                Link("Источник", destination: url)
                    .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
