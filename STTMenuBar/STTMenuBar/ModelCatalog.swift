import Foundation

struct ModelVariant: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let plainDescription: String
    let isRecommended: Bool
    let sourceRepo: String
}

enum ModelCatalog {
    static let smallEN = ModelVariant(
        id: "whisper_small_en",
        displayName: "Small (Fastest)",
        plainDescription: "Smallest download and quickest setup. Lower accuracy.",
        isRecommended: false,
        sourceRepo: "Systran/faster-whisper-small.en"
    )

    static let mediumEN = ModelVariant(
        id: "whisper_medium_en",
        displayName: "Medium (Recommended)",
        plainDescription: "Best balance for most users. Good accuracy with moderate size.",
        isRecommended: true,
        sourceRepo: "Systran/faster-whisper-medium.en"
    )

    static let largeV3 = ModelVariant(
        id: "whisper_large_v3",
        displayName: "Large v3 (Best Accuracy)",
        plainDescription: "Largest download and slower runtime. Best transcript quality.",
        isRecommended: false,
        sourceRepo: "Systran/faster-whisper-large-v3"
    )

    static let all: [ModelVariant] = [smallEN, mediumEN, largeV3]

    static func model(for id: String) -> ModelVariant? {
        all.first(where: { $0.id == id })
    }

    static var defaultModelID: String {
        mediumEN.id
    }
}

struct RemoteModelInfo: Codable {
    enum SizeSource: String, Codable {
        case exact
        case fallback
    }

    let id: String
    let repo: String
    let displayName: String
    let downloadBytes: Int64
    let sizeSource: SizeSource
}
