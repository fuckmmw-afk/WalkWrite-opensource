import SwiftUI
import StoreKit
import Foundation // Added for PurchaseManager dependencies
// Removed UIKit import; SwiftUI might handle UIImage resolution

/// Simple sheet that shows branding, a short description and links to the
/// Terms of Service and Privacy Policy. This fulfils App Store requirements
/// for legal documents.
struct InfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var brain = BrainSettings.shared

    private let accent = Color.accentColor

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "mic")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom)

                VStack(spacing: 4) {
                    Text("Дикта")
                        .font(.title).bold()

                    Text("Локальный ASR, мозг — Cloudflare Workers AI")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Picker("Мозг", selection: $brain.mode) {
                    ForEach(BrainMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("URL Cloudflare Worker")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://dicta-brain.<subdomain>.workers.dev", text: $brain.workerURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                    Text("Ключ Cloudflare в приложении не хранится. POST { raw_transcript, locale: \"ru\" }.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Purchase / Restore section
                if !PurchaseManager.shared.isUnlocked {
                    VStack(spacing: 12) {
                        Button("Full Lifetime Unlock – $1.99") {
                            Task {
                                do {
                                    await PurchaseManager.shared.loadProduct() // Ensure product is loaded
                                    try await PurchaseManager.shared.buy()
                                } catch {
                                    print("Purchase failed: \(error)")
                                    // Optionally show an alert to the user here
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        // Restore purchases button required by App Store Review Guideline 3.1.1
                        Button("Restore Purchase") {
                            Task { await PurchaseManager.shared.restore() }
                        }
                        .font(.footnote)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("Full Lifetime Unlocked – Thank you!")
                            .font(.footnote)
                            .foregroundStyle(.green)

                        // Even after an unlock, keep the Restore button visible so that users
                        // who reinstall the app (or reviewers using test accounts) can easily
                        // restore their purchase again from a single, predictable place.
                        Button("Restore Purchase") {
                            Task { await PurchaseManager.shared.restore() }
                        }
                        .font(.footnote)
                    }
                }

                Text("Запись и Whisper остаются на телефоне. Определение по умолчанию собирает Worker на Cloudflare (`env.AI`). Без сети — локальный Qwen-3 0.6B.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(spacing: 16) {
                    Link(destination: URL(string: "https://motivationstack.com/Terms")!) {
                        Label("Terms of Service", systemImage: "doc.text")
                    }
                    Link(destination: URL(string: "https://motivationstack.com/privacy")!) {
                        Label("Privacy Policy", systemImage: "lock.shield")
                    }
                }

                Spacer()

                HStack(spacing: 2) {
                    Text("Made with ❤️ by")
                    Link("Louie Bacaj", destination: URL(string: "https://x.com/lbacaj")!)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom)
            }
            .padding()
            }
            .task { await PurchaseManager.shared.loadProduct() }
            .navigationTitle("About")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: { dismiss() }) } }
        }
    }
}

// Removed private struct AppIconView to avoid UIImage dependency issues.

#Preview {
    InfoSheet()
}
