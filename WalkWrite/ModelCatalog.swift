import Foundation

struct RemoteFile: Hashable, Sendable {
    let repo: String
    let path: String
    let bytes: Int64

    var url: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)?download=true")!
    }
}

struct ASRModelSpec: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let file: RemoteFile
    let turboDTW: Bool
}

struct LLMModelSpec: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let files: [RemoteFile]
}

enum ModelCatalog {
    static let asr: [ASRModelSpec] = [
        ASRModelSpec(
            id: "whisper-tiny-q5",
            title: "Whisper Tiny Q5",
            detail: "~31 МБ · быстро, слабее по русскому",
            file: RemoteFile(repo: "ggerganov/whisper.cpp", path: "ggml-tiny-q5_1.bin", bytes: 32_152_673),
            turboDTW: false
        ),
        ASRModelSpec(
            id: "whisper-base-q5",
            title: "Whisper Base Q5",
            detail: "~57 МБ · быстрее tiny, всё ещё лёгкая",
            file: RemoteFile(repo: "ggerganov/whisper.cpp", path: "ggml-base-q5_1.bin", bytes: 59_707_625),
            turboDTW: false
        ),
        ASRModelSpec(
            id: "whisper-small-q5",
            title: "Whisper Small Q5",
            detail: "~181 МБ · нормальный русский, по умолчанию",
            file: RemoteFile(repo: "ggerganov/whisper.cpp", path: "ggml-small-q5_1.bin", bytes: 190_085_487),
            turboDTW: false
        ),
        ASRModelSpec(
            id: "whisper-small",
            title: "Whisper Small",
            detail: "~466 МБ · точнее quant small",
            file: RemoteFile(repo: "ggerganov/whisper.cpp", path: "ggml-small.bin", bytes: 487_601_967),
            turboDTW: false
        ),
        ASRModelSpec(
            id: "whisper-medium-q5",
            title: "Whisper Medium Q5",
            detail: "~514 МБ · лучше качество, тяжелее",
            file: RemoteFile(repo: "ggerganov/whisper.cpp", path: "ggml-medium-q5_0.bin", bytes: 539_212_467),
            turboDTW: false
        ),
        ASRModelSpec(
            id: "whisper-turbo-q5",
            title: "Whisper Large v3 Turbo Q5",
            detail: "~547 МБ · как в оригинальном WalkWrite",
            file: RemoteFile(repo: "ggerganov/whisper.cpp", path: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195),
            turboDTW: true
        ),
        ASRModelSpec(
            id: "whisper-turbo-q8",
            title: "Whisper Large v3 Turbo Q8",
            detail: "~834 МБ · точнее turbo Q5",
            file: RemoteFile(repo: "ggerganov/whisper.cpp", path: "ggml-large-v3-turbo-q8_0.bin", bytes: 874_188_075),
            turboDTW: true
        ),
    ]

    static let defaultASRId = "whisper-small-q5"

    static let llm: LLMModelSpec = LLMModelSpec(
        id: "qwen3-0.6b-4bit",
        title: "Qwen3 0.6B 4-bit",
        detail: "~335 МБ · локальный запасной мозг",
        files: [
            RemoteFile(repo: "mlx-community/Qwen3-0.6B-4bit", path: "config.json", bytes: 937),
            RemoteFile(repo: "mlx-community/Qwen3-0.6B-4bit", path: "model.safetensors", bytes: 335_450_584),
            RemoteFile(repo: "mlx-community/Qwen3-0.6B-4bit", path: "tokenizer.json", bytes: 11_422_654),
            RemoteFile(repo: "mlx-community/Qwen3-0.6B-4bit", path: "tokenizer_config.json", bytes: 9_706),
            RemoteFile(repo: "mlx-community/Qwen3-0.6B-4bit", path: "merges.txt", bytes: 1_671_853),
            RemoteFile(repo: "mlx-community/Qwen3-0.6B-4bit", path: "vocab.json", bytes: 2_776_833),
            RemoteFile(repo: "mlx-community/Qwen3-0.6B-4bit", path: "added_tokens.json", bytes: 707),
            RemoteFile(repo: "mlx-community/Qwen3-0.6B-4bit", path: "special_tokens_map.json", bytes: 613),
        ]
    )

    static func asr(_ id: String) -> ASRModelSpec? {
        asr.first { $0.id == id }
    }
}
