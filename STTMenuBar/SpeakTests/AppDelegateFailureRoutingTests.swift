import XCTest
@testable import Speak

final class AppDelegateFailureRoutingTests: XCTestCase {
    func testSetupRecoverableParakeetErrorsRouteToSetup() {
        XCTAssertTrue(AppDelegate.shouldRouteParakeetFailureToSetup(message: "setup_required: model missing"))
        XCTAssertTrue(AppDelegate.shouldRouteParakeetFailureToSetup(message: "parakeet could not locate downloaded parakeet model artifacts"))
        XCTAssertTrue(AppDelegate.shouldRouteParakeetFailureToSetup(message: "parakeet worker says runtime not supported"))
    }

    func testTransientErrorsDoNotRouteToSetup() {
        XCTAssertFalse(AppDelegate.shouldRouteParakeetFailureToSetup(message: "network timeout while uploading logs"))
        XCTAssertFalse(AppDelegate.shouldRouteParakeetFailureToSetup(message: "transcription timed out"))
    }
}
