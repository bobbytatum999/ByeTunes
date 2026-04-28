import Foundation

enum MetadataProviderID: String, CaseIterable, Identifiable, Codable {
    case local
    case youtube
    case itunes
    case deezer
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Local Files"
        case .youtube: return "YouTube"
        case .itunes: return "iTunes API"
        case .deezer: return "Deezer API"
        case .apple: return "Apple Music"
        }
    }

    var isRemote: Bool {
        self != .local
    }
}

struct MetadataProviderSettings {
    static let sourcesKey = "metadataSourcesJSON"
    static let legacySourceKey = "metadataSource"

    static var defaultSources: [MetadataProviderID] {
        [.local, .youtube, .itunes, .deezer, .apple]
    }

    static var safeSources: [MetadataProviderID] {
        [.local, .youtube, .itunes, .deezer]
    }

    static func selectedSources() -> [MetadataProviderID] {
        migrateIfNeeded()
        if let legacy = UserDefaults.standard.string(forKey: legacySourceKey), legacy == "all" {
            return defaultSources
        }
        guard let json = UserDefaults.standard.string(forKey: sourcesKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MetadataProviderID].self, from: data) else {
            return [.local]
        }
        return decoded.isEmpty ? [.local] : decoded
    }

    static func saveSources(_ sources: [MetadataProviderID]) {
        let valid = sources.isEmpty ? [MetadataProviderID.local] : sources
        if let data = try? JSONEncoder().encode(valid),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: sourcesKey)
        }
    }

    static func migrateIfNeeded() {
        guard UserDefaults.standard.string(forKey: sourcesKey) == nil else { return }
        let old = UserDefaults.standard.string(forKey: legacySourceKey) ?? "local"
        let migrated: [MetadataProviderID]
        switch old {
        case "itunes": migrated = [.local, .itunes]
        case "deezer": migrated = [.local, .deezer]
        case "apple": migrated = [.local, .apple]
        case "all": migrated = defaultSources
        default: migrated = [.local]
        }
        saveSources(migrated)
    }

    static func addSource(_ source: MetadataProviderID) {
        var current = selectedSources()
        if !current.contains(source) {
            current.append(source)
            saveSources(current)
        }
    }

    static func removeSource(_ source: MetadataProviderID) {
        var current = selectedSources()
        current.removeAll { $0 == source }
        if current.isEmpty { current = [.local] }
        saveSources(current)
    }

    static func toggleSource(_ source: MetadataProviderID) {
        let current = selectedSources()
        if current.contains(source) {
            removeSource(source)
        } else {
            addSource(source)
        }
    }

    static func hasRemoteSource() -> Bool {
        selectedSources().contains(where: { $0.isRemote })
    }
}

struct YouTubeMetadataCandidate {
    let videoID: String
    let title: String
    let channelTitle: String
    let description: String?
    let tags: [String]
    let thumbnailURL: URL?
    let durationMs: Int?
}

struct PartialSongMetadata {
    let title: String
    let artist: String
    let album: String
    let source: MetadataProviderID
}

enum MetadataProvider {
    static func normalizeYouTubeTitle(_ rawTitle: String, channel: String) -> PartialSongMetadata {
        let cleaned = rawTitle
            .replacingOccurrences(of: "(Official Video)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Official Audio)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[Lyrics]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Lyrics)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Visualizer)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(AMV)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Remix)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Unreleased)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(Leak)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "prod.", with: "prod.", options: .caseInsensitive)
            .replacingOccurrences(of: "ft.", with: "feat.", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains(" - ") {
            let parts = cleaned.split(separator: "-", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return PartialSongMetadata(
                title: parts.count > 1 ? parts[1] : cleaned,
                artist: parts.first ?? channel,
                album: "YouTube",
                source: .youtube
            )
        }
        return PartialSongMetadata(
            title: cleaned,
            artist: channel,
            album: "YouTube",
            source: .youtube
        )
    }

    static func extractYouTubeVideoID(from urlString: String) -> String? {
        let patterns = [
            #"(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/)([a-zA-Z0-9_-]{11})"#,
            #"^([a-zA-Z0-9_-]{11})$"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
               let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        return nil
    }

    static func fetchYouTubeMetadata(videoID: String, apiKey: String? = nil) async -> YouTubeMetadataCandidate? {
        let key = apiKey ?? ""
        guard !key.isEmpty else { return nil }
        let urlString = "https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails&id=\(videoID)&key=\(key)"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let items = json?["items"] as? [[String: Any]], let first = items.first else { return nil }

            let snippet = first["snippet"] as? [String: Any] ?? [:]
            let contentDetails = first["contentDetails"] as? [String: Any] ?? [:]

            let title = snippet["title"] as? String ?? ""
            let channelTitle = snippet["channelTitle"] as? String ?? ""
            let description = snippet["description"] as? String
            let tags = snippet["tags"] as? [String] ?? []
            let thumbnailURL = (snippet["thumbnails"] as? [String: Any])?["high"] as? [String: Any]? ?? (snippet["thumbnails"] as? [String: Any])?["default"] as? [String: Any]
            let thumbURL = thumbnailURL?["url"] as? String

            var durationMs: Int?
            if let isoDuration = contentDetails["duration"] as? String {
                durationMs = parseISO8601Duration(isoDuration)
            }

            return YouTubeMetadataCandidate(
                videoID: videoID,
                title: title,
                channelTitle: channelTitle,
                description: description,
                tags: tags,
                thumbnailURL: thumbURL.flatMap { URL(string: $0) },
                durationMs: durationMs
            )
        } catch {
            Logger.shared.log("[YouTubeProvider] Fetch failed: \(error)")
            return nil
        }
    }

    private static func parseISO8601Duration(_ duration: String) -> Int? {
        let pattern = #"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = duration as NSString
        let results = regex.matches(in: duration, range: NSRange(location: 0, length: nsString.length))
        guard let match = results.first else { return nil }

        var totalMs = 0
        if let hoursRange = Range(match.range(at: 1), in: duration), let hours = Int(duration[hoursRange]) {
            totalMs += hours * 3600000
        }
        if let minutesRange = Range(match.range(at: 2), in: duration), let minutes = Int(duration[minutesRange]) {
            totalMs += minutes * 60000
        }
        if let secondsRange = Range(match.range(at: 3), in: duration), let seconds = Int(duration[secondsRange]) {
            totalMs += seconds * 1000
        }
        return totalMs > 0 ? totalMs : nil
    }
}
