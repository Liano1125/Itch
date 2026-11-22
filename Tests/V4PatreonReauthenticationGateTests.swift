import XCTest
@testable import itchPocket

final class V4PatreonReauthenticationGateTests: XCTestCase {
    func testLegacyPatreonSessionIsDeletedOnlyOnce() throws {
        var marker: String?
        var deleteCount = 0
        var savedMarker: (String, String)?

        let reset = {
            try V4PatreonReauthenticationGate.resetIfNeeded(
                readMarker: { marker },
                deleteLegacyToken: { deleteCount += 1 },
                saveMarker: { value, key in
                    savedMarker = (value, key)
                    marker = value
                }
            )
        }

        try reset()
        try reset()

        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(savedMarker?.0, "completed")
        XCTAssertEqual(savedMarker?.1, V4PatreonReauthenticationGate.completionKey)
    }

    func testFailedMarkerWriteDoesNotPretendResetWasRecorded() {
        var marker: String?
        var deleteCount = 0

        XCTAssertThrowsError(
            try V4PatreonReauthenticationGate.resetIfNeeded(
                readMarker: { marker },
                deleteLegacyToken: { deleteCount += 1 },
                saveMarker: { _, _ in throw TestError.markerWriteFailed }
            )
        )

        XCTAssertNil(marker)
        XCTAssertEqual(deleteCount, 1)
    }

    private enum TestError: Error {
        case markerWriteFailed
    }
}
