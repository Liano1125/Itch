import Foundation

/// Restricts Patreon discovery to the canonical itch.io primary-author profile.
/// Game pages are intentionally never inspected for Patreon links because they
/// can contain links belonging to collaborators or unrelated promotions.
enum PatreonCreatorLinkResolver {
    static func authorProfilePage(
        in pages: [(URL, String)],
        matching authorURL: URL?
    ) -> (URL, String)? {
        guard let authorURL else { return nil }
        return pages.first { $0.0 == authorURL }
    }

    static func patreonURL(in html: String, baseURL: URL) -> URL? {
        let pattern = #"<a[^>]+href=["'](https?://(?:www\.)?patreon\.com/[^"'#? ]+|/[^"'#? ]*patreon[^"'#? ]*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let raw = String(html[capture])
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }
}
