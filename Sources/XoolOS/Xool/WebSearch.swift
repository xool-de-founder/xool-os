import Foundation

/// The agent's `web_search`: SearXNG when `XOOL_SEARXNG` names an instance,
/// else DuckDuckGo's HTML page (as jarvis-on-nod's werkzeuge.py does). It
/// leaves this Mac with the query and nothing else: no cookies, no account.
enum WebSearch {
    struct Hit: Equatable {
        var title: String
        var url: String
        var snippet: String
    }

    private static var session: URLSession {
        ProxyNetwork.kept("xool-search") {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 15
            ProxyNetwork.stamp(configuration)
            return URLSession(configuration: configuration)
        }
    }

    static func search(_ query: String, count: Int = 6) async throws -> [Hit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if let base = getenv("XOOL_SEARXNG").map({ String(cString: $0) }), !base.isEmpty,
           var parts = URLComponents(string: base.hasSuffix("/") ? base + "search" : base + "/search") {
            parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
            if let url = parts.url, ["http", "https"].contains(url.scheme ?? "") {
                let (data, _) = try await session.data(from: url)
                return Array(parseSearXNG(data).prefix(count))
            }
        }
        var parts = URLComponents(string: "https://html.duckduckgo.com/html/")!
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: parts.url!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return Array(parseDuckDuckGo(String(decoding: data, as: UTF8.self)).prefix(count))
    }

    static func parseSearXNG(_ data: Data) -> [Hit] {
        let results = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return results.compactMap { item in
            guard let url = item["url"] as? String, let title = item["title"] as? String else { return nil }
            return Hit(title: title, url: url, snippet: (item["content"] as? String) ?? "")
        }
    }

    /// `result__a` links (the address is behind duckduckgo.com/l/?uddg=) and
    /// the `result__snippet` after each.
    static func parseDuckDuckGo(_ html: String) -> [Hit] {
        guard let link = try? NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators]),
              let snip = try? NSRegularExpression(pattern: #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        else { return [] }
        let whole = NSRange(html.startIndex..., in: html)
        let snippets = snip.matches(in: html, range: whole).compactMap { Range($0.range(at: 1), in: html).map { text(String(html[$0])) } }
        var hits: [Hit] = []
        for (index, match) in link.matches(in: html, range: whole).enumerated() {
            guard let h = Range(match.range(at: 1), in: html), let t = Range(match.range(at: 2), in: html),
                  let url = destination(String(html[h])) else { continue }
            hits.append(Hit(title: text(String(html[t])), url: url, snippet: index < snippets.count ? snippets[index] : ""))
        }
        return hits
    }

    /// The real address inside DuckDuckGo's redirect, or the link itself.
    static func destination(_ href: String) -> String? {
        var text = href.replacingOccurrences(of: "&amp;", with: "&")
        if text.hasPrefix("//") { text = "https:" + text }
        if let parts = URLComponents(string: text), parts.host?.hasSuffix("duckduckgo.com") == true,
           let target = parts.queryItems?.first(where: { $0.name == "uddg" })?.value {
            text = target
        }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""), url.host?.hasSuffix("duckduckgo.com") != true else { return nil }
        return text
    }

    /// Tags out, entities in.
    static func text(_ html: String) -> String {
        var out = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
