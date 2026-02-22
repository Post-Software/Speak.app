import Foundation

struct ModelVariant: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let plainDescription: String
    let isRecommended: Bool
    let sourceRepo: String
    let sourceType: String
    let estimatedRuntimeMemoryBytes: Int64
}

enum ModelCatalog {
    static let fast = ModelVariant(
        id: "voxtral_q4_fast",
        displayName: "Recommended",
        plainDescription: "Smaller download and quicker setup. Best for most people.",
        isRecommended: true,
        sourceRepo: "TrevorJS/voxtral-mini-realtime-gguf",
        sourceType: "community",
        estimatedRuntimeMemoryBytes: 700 * 1024 * 1024
    )

    static let quality = ModelVariant(
        id: "voxtral_full_quality",
        displayName: "Better Accuracy",
        plainDescription: "Larger download, but better accuracy if you have disk space.",
        isRecommended: false,
        sourceRepo: "mistralai/Voxtral-Mini-4B-Realtime-2602",
        sourceType: "official",
        estimatedRuntimeMemoryBytes: 9 * 1024 * 1024 * 1024
    )

    static let all: [ModelVariant] = [fast, quality]

    static func model(for id: String) -> ModelVariant? {
        all.first(where: { $0.id == id })
    }
}

struct RemoteModelInfo: Codable {
    let id: String
    let repo: String
    let displayName: String
    let downloadBytes: Int64
    let estimatedRuntimeMemoryBytes: Int64
}
