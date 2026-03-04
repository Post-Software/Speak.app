import XCTest
@testable import Speak

final class ModelCatalogTests: XCTestCase {
    func testModelCatalogContainsExpectedModelsInOrder() {
        let ids = ModelCatalog.all.map(\.id)
        XCTAssertEqual(ids, [
            "parakeet_tdt_0_6b_v3",
            "whisper_small_en",
            "whisper_medium_en",
            "whisper_large_v3"
        ])
    }

    func testDefaultModelIsParakeet() {
        XCTAssertEqual(ModelCatalog.defaultModelID, "parakeet_tdt_0_6b_v3")
    }

    func testKnownModelIDsRemainStable() {
        XCTAssertEqual(ModelCatalog.parakeetTdtV3.id, "parakeet_tdt_0_6b_v3")
        XCTAssertEqual(ModelCatalog.smallEN.id, "whisper_small_en")
        XCTAssertEqual(ModelCatalog.mediumEN.id, "whisper_medium_en")
        XCTAssertEqual(ModelCatalog.largeV3.id, "whisper_large_v3")
    }
}
