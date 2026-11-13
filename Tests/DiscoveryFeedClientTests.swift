import XCTest
@testable import itchPocket

final class DiscoveryFeedClientTests: XCTestCase {
    func testExtractsGameCardFieldsFromNestedItchMarkup() throws {
        let html = """
        <div class="game_cell" data-game_id="12345">
          <div class="game_thumb">
            <a href="https://sample-dev.itch.io/sample-game">
              <img data-lazy_src="//img.itch.zone/aW1hZ2UvMTIzLmpwZw==/315x250%23c/sample.jpg" />
            </a>
          </div>
          <div class="game_title">
            <a class="title" href="https://sample-dev.itch.io/sample-game">Sample &amp; Story</a>
          </div>
          <div class="game_author"><a href="https://sample-dev.itch.io/">Sample Dev</a></div>
          <div class="game_text"><p>A short <strong>description</strong>.</p></div>
          <div class="game_platforms"><span>Windows</span><span>Linux</span></div>
        </div>
        """
        let baseURL = try XCTUnwrap(URL(string: "https://itch.io/games/tag-renpy/tag-adult"))
        let cards = DiscoveryFeedClient.extractGameCards(from: html, baseURL: baseURL)

        XCTAssertEqual(cards.count, 1)
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card["id"] as? String, "12345")
        XCTAssertEqual(card["title"] as? String, "Sample & Story")
        XCTAssertEqual(card["url"] as? String, "https://sample-dev.itch.io/sample-game")
        XCTAssertEqual(card["developer"] as? String, "Sample Dev")
        XCTAssertEqual(card["developerProfileURL"] as? String, "https://sample-dev.itch.io/")
        XCTAssertEqual(card["description"] as? String, "A short description.")
        XCTAssertTrue((card["coverURL"] as? String)?.contains("img.itch.zone") == true)
    }

    func testDeduplicatesRepeatedGameCardsByStableGameID() throws {
        let card = """
        <div class="game_cell" data-game_id="123">
          <div class="game_title"><a class="title" href="/sample">Sample Game</a></div>
        </div>
        """
        let html = card + card
        let baseURL = try XCTUnwrap(URL(string: "https://itch.io/games"))
        let cards = DiscoveryFeedClient.extractGameCards(from: html, baseURL: baseURL)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?["id"] as? String, "123")
    }
}
