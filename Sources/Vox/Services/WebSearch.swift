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
    /// HTTPS only (the old lookup went over plain HTTP, so anyone on the network could see or fake it).
    static func approximateLocation() async -> (lat: Double, lon: Double, city: String)? {
        for endpoint in ["https://get.geojs.io/v1/ip/geo.json", "https://ipwho.is/?fields=city,latitude,longitude"] {
            guard let url = URL(string: endpoint),
                  let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 4)),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lat = number(j["latitude"]), let lon = number(j["longitude"]) else { continue }
            return (lat, lon, (j["city"] as? String)?.nilIfEmpty ?? "your area")
        }
        return nil
    }

    /// geojs sends coordinates as strings, ipwho.is as numbers.
    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        return (v as? String).flatMap(Double.init)
    }
}
