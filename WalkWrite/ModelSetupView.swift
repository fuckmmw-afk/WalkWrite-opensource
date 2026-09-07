import SwiftUI

struct ModelSetupView: View {
    @ObservedObject var models = ModelManager.shared
    var canDismiss: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Модели качаются с Hugging Face после установки. В IPA их нет.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Расшифровка (ASR)") {
                    ForEach(ModelCatalog.asr) { spec in
                        asrRow(spec)
                    }
                }

                Section("Запасной мозг офлайн") {
                    llmRow
                }

                if let err = models.lastError {
                    Section {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Модели")
            .toolbar {
                if canDismiss || models.asrReady {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { dismiss() }
                            .disabled(!models.asrReady)
                    }
                }
            }
        }
        .interactiveDismissDisabled(!models.asrReady && !canDismiss)
    }

    private func asrRow(_ spec: ASRModelSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(spec.title).font(.headline)
                    Text(spec.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if models.selectedASRId == spec.id && models.isDownloaded(asr: spec) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if models.busyId == spec.id {
                ProgressView(value: models.progress[spec.id] ?? 0)
            }
            HStack {
                if models.isDownloaded(asr: spec) {
                    Button("Выбрать") {
                        Task { await models.selectASR(spec) }
                    }
                    .disabled(models.busyId != nil || models.selectedASRId == spec.id)
                } else {
                    Button("Скачать") {
                        Task { await models.downloadASR(spec) }
                    }
                    .disabled(models.busyId != nil)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var llmRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ModelCatalog.llm.title).font(.headline)
            Text(ModelCatalog.llm.detail).font(.caption).foregroundStyle(.secondary)
            if models.busyId == ModelCatalog.llm.id {
                ProgressView(value: models.progress[ModelCatalog.llm.id] ?? 0)
            }
            if models.llmReady {
                Label("Скачана", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Скачать для офлайна") {
                    Task { await models.downloadLLM() }
                }
                .disabled(models.busyId != nil)
            }
        }
        .padding(.vertical, 4)
    }
}
