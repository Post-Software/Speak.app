import Foundation

enum ModelEngine: String, Codable {
    case whisper
    case parakeetTDTV3 = "parakeet_tdt_v3"
}

struct ModelVariant: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let plainDescription: String
    let isRecommended: Bool
    let sourceRepo: String
    let engine: ModelEngine
}

enum ModelCatalog {
    static let parakeetTdtV3 = ModelVariant(
        id: "parakeet_tdt_0_6b_v3",
        displayName: "Parakeet v3 (Default)",
        plainDescription: "Fast, accurate transcription for most Apple Silicon Macs. If it can't run here, Speak switches to Small automatically.",
        isRecommended: true,
        sourceRepo: "nemo-parakeet-tdt-0.6b-v3",
        engine: .parakeetTDTV3
    )

    static let smallEN = ModelVariant(
        id: "whisper_small_en",
        displayName: "Small (Fastest)",
        plainDescription: "Smallest download and fastest setup. Best fallback choice, with lower accuracy.",
        isRecommended: false,
        sourceRepo: "Systran/faster-whisper-small.en",
        engine: .whisper
    )

    static let mediumEN = ModelVariant(
        id: "whisper_medium_en",
        displayName: "Medium (Recommended)",
        plainDescription: "Balanced speed and accuracy with a moderate download size.",
        isRecommended: true,
        sourceRepo: "Systran/faster-whisper-medium.en",
        engine: .whisper
    )

    static let largeV3 = ModelVariant(
        id: "whisper_large_v3",
        displayName: "Large v3 (Best Accuracy)",
        plainDescription: "Highest accuracy, largest download, and slower performance.",
        isRecommended: false,
        sourceRepo: "Systran/faster-whisper-large-v3",
        engine: .whisper
    )

    static let all: [ModelVariant] = [parakeetTdtV3, smallEN, mediumEN, largeV3]

    static func model(for id: String) -> ModelVariant? {
        all.first(where: { $0.id == id })
    }

    static var defaultModelID: String {
        parakeetTdtV3.id
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

struct RuntimeSupportInfo: Codable {
    let modelID: String
    let supported: Bool
    let status: String
    let reason: String
    let requiresInstall: Bool

    var isHardUnsupported: Bool {
        !supported && !requiresInstall
    }
}
