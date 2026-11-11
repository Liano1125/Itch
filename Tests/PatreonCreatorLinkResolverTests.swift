import XCTest
@testable import itchPocket

final class PatreonCreatorLinkResolverTests: XCTestCase {
    func testOnlyPrimaryAuthorProfileCanSupplyPatreonLink() throws {
        let authorURL = try XCTUnwrap(URL(string: "https://primary.itch.io"))
        let gameURL = try XCTUnwrap(URL(string: "https://primary.itch.io/game"))
        let authorHTML = "<html><body><a href=\"https://primary.itch.io/about\">About</a></body></html>"
        let gameHTML = "<html><body><a href=\"https://www.patreon.com/collaborator\">Support</a></body></html>"
        let pages = [(authorURL, authorHTML), (gameURL, gameHTML)]

        let authorPage = PatreonCreatorLinkResolver.authorProfilePage(
            in: pages,
            matching: authorURL
        )

        XCTAssertEqual(authorPage?.0, authorURL)
        XCTAssertEqual(authorPage?.1, authorHTML)
        XCTAssertNil(
            PatreonCreatorLinkResolver.patreonURL(
                in: try XCTUnwrap(authorPage).1,
                baseURL: authorURL
            )
        )
    }

    func testPatreonLinkOnPrimaryAuthorProfileIsResolved() throws {
        let authorURL = try XCTUnwrap(URL(string: "https://primary.itch.io"))
        let html = """
        <html><body>
          <a href="https://www.patreon.com/primary_creator">Patreon</a>
        </body></html>
        """

        XCTAssertEqual(
            PatreonCreatorLinkResolver.patreonURL(in: html, baseURL: authorURL)?.absoluteString,
            "https://www.patreon.com/primary_creator"
        )
    }

    func testMissingPrimaryAuthorDoesNotFallBackToGamePage() throws {
        let gameURL = try XCTUnwrap(URL(string: "https://primary.itch.io/game"))
        let gameHTML = #"<a href="https://www.patreon.com/collaborator">Support</a>"#

        XCTAssertNil(
            PatreonCreatorLinkResolver.authorProfilePage(
                in: [(gameURL, gameHTML)],
                matching: nil
            )
        )
    }

    func testRelativePatreonLinkResolvesAgainstAuthorProfile() throws {
        let authorURL = try XCTUnwrap(URL(string: "https://primary.itch.io"))
        let html = #"<a href="/patreon/primary_creator">Patreon</a>"#

        XCTAssertEqual(
            PatreonCreatorLinkResolver.patreonURL(in: html, baseURL: authorURL)?.absoluteString,
            "https://primary.itch.io/patreon/primary_creator"
        )
    }
}
