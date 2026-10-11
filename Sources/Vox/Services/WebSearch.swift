import Foundation

/// A few search-result snippets for grounding spoken answers, so facts come from the web rather than
/// the small on-device model's memory. Best effort: a slow or failed lookup just returns nothing.
enum WebSearch {
    static func snippets(_ query: String, limit: Int = 4) async -> [String] {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [.init(name: "q", value: query)]
        var req = URLRequest(url: c.url!, timeoutInterval: 3)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req), let html = String(data: data, encoding: .utf8) else { return [] }
        return html.matches(of: #/class="result__snippet"[^>]*>(.*?)</a>/#.dotMatchesNewlines()).prefix(limit).map { m in
            let text = String(m.1).replacing(#/<[^>]+>/#, with: "")
            return decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        for (e, c) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: e, with: c)
        }
        return out
    }

    /// Rough location from the network (city level), used for weather when Location isn't allowed.
    static func approximateLocation() async -> (lat: Double, lon: Double, city: String)? {
        guard let url = URL(string: "http://ip-api.com/json/?fields=city,lat,lon"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lat = (j["lat"] as? NSNumber)?.doubleValue, let lon = (j["lon"] as? NSNumber)?.doubleValue else { return nil }
        return (lat, lon, j["city"] as? String ?? "your area")
    }
}
