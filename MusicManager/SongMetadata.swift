import Foundation
import AVFoundation
import UIKit


struct SongMetadata: Identifiable {
    let id = UUID()
    
    var localURL: URL
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var genre: String
    var year: Int
    var durationMs: Int
    var fileSize: Int
    var remoteFilename: String
    var artworkData: Data?
    var artworkPreviewData: Data? = nil
    
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var lyrics: String?
    
    var storeId: Int64 = 0
    var storefrontId: Int64 = 0
    var artistId: Int64 = 0
    var composerId: Int64 = 0
    var playlistId: Int64 = 0
    var genreStoreId: Int64 = 0
    var explicitRating: Int = 0
    var copyright: String?
    var xid: String?
    var releaseDate: Int = 0
    
    var richAppleMetadataFetched: Bool = false
    
    
    var artworkToken: String {
        return "local://\(remoteFilename)"
    }
    
    
    static func generateRemoteFilename(withExtension ext: String? = nil) -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let randomName = String((0..<12).map { _ in letters.randomElement()! })
        let e = (ext?.isEmpty == false) ? ext!.lowercased() : "mp3"
        return "\(randomName).\(e)"
    }
    
    
    static func generatePersistentId() -> Int64 {
        return Int64.random(in: 1_000_000_000_000_000_000...Int64.max)
    }

    static func shouldPreserveLocalFile(_ url: URL) -> Bool {
        guard UserDefaults.standard.bool(forKey: "keepDownloadedSongs") else { return false }
        let persistentDirectory = URL.documentsDirectory.appendingPathComponent("Downloaded Songs", isDirectory: true)
        let standardizedFilePath = url.standardizedFileURL.path
        let standardizedDirectoryPath = persistentDirectory.standardizedFileURL.path + "/"
        return standardizedFilePath.hasPrefix(standardizedDirectoryPath)
    }
    
    
    static func generateGroupingKey(_ text: String) -> Data {
        guard !text.isEmpty else { return Data() }
        
        var result = [UInt8]()
        for char in text.uppercased() {
            if char >= "A" && char <= "Z" {
                result.append(UInt8(char.asciiValue! - Character("A").asciiValue! + 1))
            } else if char == " " {
                result.append(0x04)
            } else if char == "/" {
                result.append(0x0A)
            }
        }
        return Data(result)
    }
    
    static func canonicalGenre(_ raw: String?) -> String {
        guard let raw else { return "Music" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Music" }
        
        let lowered = trimmed.lowercased()
        let unknownSet: Set<String> = [
            "unknown",
            "unknown genre",
            "n/a",
            "na",
            "none",
            "null",
            "(null)"
        ]
        if unknownSet.contains(lowered) {
            return "Music"
        }
        return trimmed
    }

    
    static func fromURL(_ url: URL, includeArtwork: Bool = true) async throws -> SongMetadata {
        let asset = AVURLAsset(url: url)
        
        
        let duration = try await asset.load(.duration)
        let durationMs = Int(CMTimeGetSeconds(duration) * 1000)
        
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        
        
        let filenameWithoutExt = url.deletingPathExtension().lastPathComponent
        var title = filenameWithoutExt
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var albumArtist: String?
        var genre = "Music"
        var year = Calendar.current.component(.year, from: Date())
        var artworkData: Data?
        
        var trackNumber: Int?
        var trackCount: Int?
        var discNumber: Int?
        var discCount: Int?
        var lyrics: String?
        
        let isM4A = url.pathExtension.lowercased() == "m4a"
        var storeId: Int64 = 0
        var storefrontId: Int64 = 0
        var artistId: Int64 = 0
        var composerId: Int64 = 0
        var playlistId: Int64 = 0
        var genreStoreId: Int64 = 0
        var explicitRating: Int = 0
        var copyright: String?
        var xid: String?
        var releaseDate: Int = 0
        
        
        
        let commonMetadata = try await asset.load(.commonMetadata)

        
        for item in commonMetadata {
            guard let key = item.commonKey else { continue }
            
            switch key {
            case .commonKeyTitle:
                if let value = try? await item.load(.stringValue), !value.isEmpty {
                    title = value
                }
            case .commonKeyArtist:
                if let value = try? await item.load(.stringValue), !value.isEmpty {
                    artist = value
                }
            case .commonKeyAlbumName:
                if let value = try? await item.load(.stringValue), !value.isEmpty {
                    album = value
                }
            case .commonKeyType:
                if let value = try? await item.load(.stringValue), !value.isEmpty {
                    genre = value
                }
            case .commonKeyCreationDate:
                if let value = try? await item.load(.stringValue),
                   let extracted = extractYear(from: value) {
                    year = extracted
                }
            case .commonKeyArtwork:
                if includeArtwork, let data = try? await item.load(.dataValue) {
                    artworkData = data
                    Logger.shared.log("[SongMetadata] Extracted artwork: \(data.count) bytes")
                }
            default: break
            }
        }
        
        
        let allMetadata = try await asset.load(.metadata)
        
        
        for item in allMetadata {
            
            var keyString = ""
            if let strKey = item.key as? String {
                keyString = strKey
            } else if let intKey = item.key as? Int {
                
                
                keyString = "\(intKey)"
            }
            
            let identifier = item.identifier?.rawValue ?? ""
            let combined = "\(identifier)|\(keyString)".uppercased()
            
            if isM4A {
                let id = identifier
                let isAppleKey = id.contains("rtng") || id.contains("geID") || id.contains("sfID") || id.contains("atID") || id.contains("cmID") || id.contains("plID") || id.contains("cnID") || id.contains("cprt") || id.contains("xid")
                
                if isAppleKey {
                    if let val = try? await item.load(.stringValue), !val.isEmpty {
                        if id.contains("rtng"), let v = Int(val) { explicitRating = v }
                        if id.contains("geID"), let v = Int64(val) { genreStoreId = v }
                        if id.contains("sfID"), let v = Int64(val) { storefrontId = v }
                        if id.contains("atID"), let v = Int64(val) { artistId = v }
                        if id.contains("cmID"), let v = Int64(val) { composerId = v }
                        if id.contains("plID"), let v = Int64(val) { playlistId = v }
                        if id.contains("cnID"), let v = Int64(val) { storeId = v }
                        if id.contains("cprt") { copyright = val }
                        if id.contains("xid") { xid = val }
                    } else if let data = try? await item.load(.dataValue) {
                        if id.contains("rtng") && data.count >= 1 { explicitRating = Int(data[0]) }
                        if data.count >= 4 {
                            let intVal = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                            let val64 = Int64(intVal)
                            if id.contains("geID") { genreStoreId = val64 }
                            if id.contains("sfID") { storefrontId = val64 }
                            if id.contains("atID") { artistId = val64 }
                            if id.contains("cmID") { composerId = val64 }
                            if id.contains("plID") { playlistId = val64 }
                            if id.contains("cnID") { storeId = val64 }
                        }
                    }
                }
                
                if keyString == "\u{00A9}day" {
                    if let val = try? await item.load(.stringValue), !val.isEmpty {
                        let df = DateFormatter()
                        df.locale = Locale(identifier: "en_US_POSIX")
                        
                        let formats = [
                            "yyyy-MM-dd'T'HH:mm:ssZ",
                            "yyyy-MM-dd'T'HH:mm:ss",
                            "yyyy-MM-dd",
                            "yyyy"
                        ]
                        
                        for fmt in formats {
                            df.dateFormat = fmt
                            if let date = df.date(from: val) {
                                releaseDate = Int(date.timeIntervalSinceReferenceDate)
                                Logger.shared.log("[SongMetadata] M4A release date: \(val) -> epoch \(releaseDate)")
                                break
                            }
                        }
                        
                        if let extracted = extractYear(from: val) {
                            year = extracted
                            Logger.shared.log("[SongMetadata] M4A year from ©day: \(year)")
                        }
                    }
                }
            }
            
            
            if trackNumber == nil {
                if combined.contains("TRCK") || combined.contains("TRACK") || combined.contains("TRKN") || keyString.lowercased() == "trkn" {
                    
                    if let stringVal = try? await item.load(.stringValue) {
                        let components = stringVal.components(separatedBy: "/")
                        if let t = Int(components[0]) { trackNumber = t }
                        if components.count > 1, let tc = Int(components[1]) { trackCount = tc }
                    }
                    
                    else if let dataVal = try? await item.load(.dataValue), dataVal.count >= 8 {
                        
                        let track = dataVal.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self).bigEndian }
                        let total = dataVal.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
                        if track > 0 { trackNumber = Int(track) }
                        if total > 0 { trackCount = Int(total) }
                    }
                }
            }
            
            
            if discNumber == nil {
                if combined.contains("TPOS") || combined.contains("DISC") || combined.contains("DISK") || keyString.lowercased() == "disk" {
                     if let stringVal = try? await item.load(.stringValue) {
                        let components = stringVal.components(separatedBy: "/")
                        if let d = Int(components[0]) { discNumber = d }
                        if components.count > 1, let dc = Int(components[1]) { discCount = dc }
                     } else if let dataVal = try? await item.load(.dataValue), dataVal.count >= 6 { 
                         
                         let disc = dataVal.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self).bigEndian }
                         let total = dataVal.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
                         if disc > 0 { discNumber = Int(disc) }
                         if total > 0 { discCount = Int(total) }
                     }
                }
            }

            
            if includeArtwork && artworkData == nil {
                
                if combined.contains("ARTWORK") || combined.contains("PICTURE") || combined.contains("APIC") || combined.contains("COVR") {
                    if let data = try? await item.load(.dataValue), !data.isEmpty {
                        artworkData = data
                        Logger.shared.log("[SongMetadata] Deep Scan extracted artwork: \(data.count) bytes (Key: \(combined))")
                    }
                }
            }

            
            if let val = try? await item.load(.stringValue), !val.isEmpty {
                if keyString == "\u{00A9}gen" || keyString == "gnre" {
                     if genre == "Music" { genre = val }
                }
                
                if (combined.contains("TITLE") || combined.contains("NAM")) && title == filenameWithoutExt { title = val }
                if (combined.contains("ARTIST") || combined.contains("PERFORMER")) && !combined.contains("ALBUMARTIST") && artist == "Unknown Artist" { artist = val }
                if combined.contains("ALBUM") && !combined.contains("ALBUMARTIST") && album == "Unknown Album" { album = val }
                if (combined.contains("GENRE") || combined.contains("GEN")) && genre == "Music" { genre = val }
                
                
                if (combined.contains("ALBUMARTIST") || combined.contains("TPE2") || combined.contains("AART")) {
                   let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                   if !trimmed.isEmpty && trimmed.lowercased() != "unknown artist" {
                       albumArtist = trimmed
                       Logger.shared.log("[SongMetadata] Extracted Album Artist: \(trimmed) from key: \(combined)")
                   } else {
                       Logger.shared.log("[SongMetadata] Ignored invalid Album Artist: '\(val)'")
                   }
                }

                
                if year == Calendar.current.component(.year, from: Date()) {
                    if combined.contains("DATE") || combined.contains("YEAR") || combined.contains("TYER") || combined.contains("TDRC") || combined.contains("DAY") {
                        if let extracted = extractYear(from: val) {
                            year = extracted
                            Logger.shared.log("[SongMetadata] Extracted year: \(year) from key: \(combined) (Val: \(val))")
                        }
                    }
                }
                
                if lyrics == nil {
                    if combined.contains("USLT") || combined.contains("LYRICS") || combined.contains("UNSYNC") || keyString == "\u{00A9}lyr" {
                         lyrics = SongMetadata.cleanLyrics(val, title: title, artist: artist)
                         Logger.shared.log("[SongMetadata] Extracted and cleaned lyrics from key: \(combined)")
                    }
                }
            }
            
            if trackNumber == nil {
                if keyString == "trkn" || combined.contains("TRKN") {
                    if let data = try? await item.load(.dataValue), data.count >= 8 {
                         let track = data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self).bigEndian }
                         let total = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
                         if track > 0 { trackNumber = Int(track) }
                         if total > 0 { trackCount = Int(total) }
                         Logger.shared.log("[SongMetadata] Extracted Track via Data: \(trackNumber ?? 0)/\(trackCount ?? 0)")
                    }
                }
            }
            if discNumber == nil {
                if keyString == "disk" || combined.contains("DISK") {
                    if let data = try? await item.load(.dataValue), data.count >= 6 {
                         let disc = data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self).bigEndian }
                         let total = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
                         if disc > 0 { discNumber = Int(disc) }
                         if total > 0 { discCount = Int(total) }
                         Logger.shared.log("[SongMetadata] Extracted Disc via Data: \(discNumber ?? 0)/\(discCount ?? 0)")
                    }
                }
            }
        }
        
        
        if let aa = albumArtist, (aa.isEmpty || aa.lowercased() == "unknown artist") {
            albumArtist = nil
        }
        
        genre = canonicalGenre(genre)

        if title == filenameWithoutExt && filenameWithoutExt.contains(" - ") {
             let parts = filenameWithoutExt.components(separatedBy: " - ")
             
             if parts.count >= 3 {
                 if let trackNum = Int(parts[0]) {
                     trackNumber = trackNum
                     artist = parts[1].trimmingCharacters(in: .whitespaces)
                     title = parts[2].trimmingCharacters(in: .whitespaces)
                     Logger.shared.log("[SongMetadata] Parsed filename (Track - Artist - Title): \(filenameWithoutExt)")
                 } else {
                     artist = parts[0].trimmingCharacters(in: .whitespaces)
                     title = parts[1].trimmingCharacters(in: .whitespaces)
                 }
             }
             else if parts.count == 2 {
                 if let trackNum = Int(parts[0]) {
                     trackNumber = trackNum
                     title = parts[1].trimmingCharacters(in: .whitespaces)
                     Logger.shared.log("[SongMetadata] Parsed filename (Track - Title): \(filenameWithoutExt)")
                 } else {
                     let p1 = parts[0].trimmingCharacters(in: .whitespaces)
                     let p2 = parts[1].trimmingCharacters(in: .whitespaces)
                     
                     let p2LooksLikeArtist = p2.contains(",") || p2.lowercased().contains("feat")
                     let p1LooksLikeArtist = p1.contains(",") || p1.lowercased().contains("feat")
                     
                     if p2LooksLikeArtist && !p1LooksLikeArtist {
                         title = p1
                         artist = p2
                         Logger.shared.log("[SongMetadata] Parsed filename (Title - Artist) [Heuristic]: \(filenameWithoutExt)")
                     } else {
                         artist = p1
                         title = p2
                         Logger.shared.log("[SongMetadata] Parsed filename (Artist - Title): \(filenameWithoutExt)")
                     }
                 }
             }
        }
        
        Logger.shared.log("[SongMetadata] Final: title=\(title), artist=\(artist), album=\(album), track=\(trackNumber ?? 0)/\(trackCount ?? 0)")
        
        if isM4A && (storeId > 0 || storefrontId > 0) {
            Logger.shared.log("[SongMetadata] M4A Apple IDs: storeId=\(storeId), sfID=\(storefrontId), atID=\(artistId), cmID=\(composerId), plID=\(playlistId), geID=\(genreStoreId), rtng=\(explicitRating)")
        }
        
        return SongMetadata(
            localURL: url,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            year: year,
            durationMs: durationMs,
            fileSize: fileSize,
            remoteFilename: generateRemoteFilename(withExtension: url.pathExtension),
            artworkData: artworkData,
            trackNumber: trackNumber,
            trackCount: trackCount,
            discNumber: discNumber,
            discCount: discCount,
            lyrics: lyrics,
            storeId: storeId,
            storefrontId: storefrontId,
            artistId: artistId,
            composerId: composerId,
            playlistId: playlistId,
            genreStoreId: genreStoreId,
            explicitRating: explicitRating,
            copyright: copyright,
            xid: xid,
            releaseDate: releaseDate
        )
    }

    static func extractEmbeddedArtwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)

        if let commonMetadata = try? await asset.load(.commonMetadata) {
            for item in commonMetadata {
                guard item.commonKey == .commonKeyArtwork else { continue }
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    return data
                }
            }
        }

        if let allMetadata = try? await asset.load(.metadata) {
            for item in allMetadata {
                var keyString = ""
                if let strKey = item.key as? String {
                    keyString = strKey
                } else if let intKey = item.key as? Int {
                    keyString = "\(intKey)"
                }

                let identifier = item.identifier?.rawValue ?? ""
                let combined = "\(identifier)|\(keyString)".uppercased()
                if combined.contains("ARTWORK") || combined.contains("PICTURE") || combined.contains("APIC") || combined.contains("COVR") {
                    if let data = try? await item.load(.dataValue), !data.isEmpty {
                        return data
                    }
                }
            }
        }

        return nil
    }

    static func extractEmbeddedArtworkThumbnail(from url: URL, maxDimension: CGFloat = 120) async -> Data? {
        guard let fullData = await extractEmbeddedArtwork(from: url) else { return nil }
        return createArtworkThumbnailData(from: fullData, maxDimension: maxDimension)
    }

    private static func createArtworkThumbnailData(from data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let size = image.size
        let largestDimension = max(size.width, size.height)
        let scale = largestDimension > maxDimension ? (maxDimension / largestDimension) : 1
        let targetSize = CGSize(
            width: max(size.width * scale, 1),
            height: max(size.height * scale, 1)
        )

        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: rendererFormat)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.72)
    }
    
    
    static private func extractYear(from string: String) -> Int? {
        
        
        
        
        do {
            let regex = try NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\b")
            let nsString = string as NSString
            let results = regex.matches(in: string, range: NSRange(location: 0, length: nsString.length))
            
            if let first = results.first {
                let match = nsString.substring(with: first.range)
                if let y = Int(match), y >= 1900 && y <= 2100 {
                    return y
                }
            }
        } catch {
            return nil
        }
        
        
        if let prefixInt = Int(string.prefix(4)), prefixInt >= 1900 && prefixInt <= 2100 {
            return prefixInt
        }
        
        return nil
    }
    
    static func cleanLyrics(_ rawLyrics: String, title: String? = nil, artist: String? = nil) -> String {
        var cleaned = rawLyrics.replacingOccurrences(of: #"\[([a-z]+):.*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        
        cleaned = cleaned.replacingOccurrences(of: #"\[\d{2,}:\d{2}(\.\d{2,})?\]"#, with: "", options: .regularExpression)
        
        cleaned = cleaned.replacingOccurrences(of: #"\d+\s+Contributors"#, with: "", options: .regularExpression)
        
        cleaned = cleaned.replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)

        let lines = cleaned.components(separatedBy: .newlines)
        var resultLines: [String] = []
        
        let noiseWords = ["lyrics", "letra", "contributors", "official", "video", "audio"]
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if let last = resultLines.last, !last.isEmpty {
                    resultLines.append("")
                }
                continue
            }
            
            if let title = title {
                let lowLine = trimmed.lowercased()
                let lowTitle = title.lowercased()
                
                if lowLine == lowTitle {
                    continue // Exact title match header
                }
                
                if lowLine.contains(lowTitle) {
                    var remainder = lowLine.replacingOccurrences(of: lowTitle, with: "")
                    for noise in noiseWords {
                        remainder = remainder.replacingOccurrences(of: noise, with: "")
                    }
                    let cleanRemainder = remainder.trimmingCharacters(in: .punctuationCharacters).trimmingCharacters(in: .whitespaces)
                    if cleanRemainder.isEmpty {
                        continue // It's a header like "Title Lyrics"
                    }
                }
            }
            
            resultLines.append(trimmed)
        }
        
        return resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fetchLyricsFromLRCLIB(title: String, artist: String, album: String, durationMs: Int) async -> String? {
        let titleEnc = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let artistEnc = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let albumEnc = album.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let durationSec = durationMs / 1000
        
        let urlString = "https://lrclib.net/api/get?artist_name=\(artistEnc)&track_name=\(titleEnc)&album_name=\(albumEnc)&duration=\(durationSec)"
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue("MusicManager/1.0.3 (https://github.com/EduAlexxis/MusicManager)", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let lyrics = (json?["plainLyrics"] as? String) ?? (json?["syncedLyrics"] as? String)
            
            if let l = lyrics, !l.isEmpty {
                Logger.shared.log("[SongMetadata] Successfully fetched lyrics from LRCLIB")
                return SongMetadata.cleanLyrics(l, title: title, artist: artist)
            }
        } catch {
            Logger.shared.log("[SongMetadata] LRCLIB fetch failed: \(error)")
        }
        return nil
    }
}

struct LRCLIBResult: Codable, Identifiable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let plainLyrics: String?
    let syncedLyrics: String?
}

extension SongMetadata {
    static func searchLyrics(query: String) async -> [LRCLIBResult] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://lrclib.net/api/search?q=\(encodedQuery)") else { return [] }
        
        var request = URLRequest(url: url)
        request.setValue("MusicManager/1.0.3 (https://github.com/EduAlexxis/MusicManager)", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let results = try JSONDecoder().decode([LRCLIBResult].self, from: data)
            return results
        } catch {
            Logger.shared.log("[SongMetadata] LRCLIB search failed: \(error)")
            return []
        }
    }

    static func applyAppleMusicMatch(_ match: AppleMusicAPI.AppleMusicSong, to song: SongMetadata) async -> SongMetadata {
        var enrichedSong = song
        let amsMatch = match
        
        enrichedSong.title = amsMatch.attributes.name
        enrichedSong.artist = amsMatch.attributes.artistName
        if let alb = amsMatch.attributes.albumName { enrichedSong.album = alb }
        if let trackNumber = amsMatch.attributes.trackNumber {
            enrichedSong.trackNumber = trackNumber
        }
        if let discNumber = amsMatch.attributes.discNumber {
            enrichedSong.discNumber = discNumber
        }
        if let durationInMillis = amsMatch.attributes.durationInMillis, durationInMillis > 0 {
            enrichedSong.durationMs = durationInMillis
        }
        
        if let songIdInt = Int64(amsMatch.id) {
            enrichedSong.storeId = songIdInt
        }
        
        if let dateStr = amsMatch.attributes.releaseDate {
            if let yearInt = Int(dateStr.prefix(4)) {
                enrichedSong.year = yearInt
            }
            if let epoch = parseDateToEpoch(dateStr) {
                enrichedSong.releaseDate = epoch
            }
        } else if let firstAlbum = amsMatch.relationships?.albums?.data.first,
                  let albDateStr = firstAlbum.attributes.releaseDate {
            if let yearInt = Int(albDateStr.prefix(4)) {
                enrichedSong.year = yearInt
            }
            if let epoch = parseDateToEpoch(albDateStr) {
                enrichedSong.releaseDate = epoch
            }
        }
        
        if let isrc = amsMatch.attributes.isrc, !isrc.isEmpty {
            enrichedSong.xid = isrc
        }
        
        if let rating = amsMatch.attributes.contentRating {
            enrichedSong.explicitRating = (rating == "explicit") ? 1 : (rating == "clean" ? 2 : 0)
        }
        
        if let firstAlbum = amsMatch.relationships?.albums?.data.first,
           let cprt = firstAlbum.attributes.copyright {
            enrichedSong.copyright = cprt
        }
        
        if let firstArtist = amsMatch.relationships?.artists?.data.first,
           let artistIdInt = Int64(firstArtist.id) {
            enrichedSong.artistId = artistIdInt
        }
        
        if let firstComposer = amsMatch.relationships?.composers?.data.first,
           let composerIdInt = Int64(firstComposer.id) {
            enrichedSong.composerId = composerIdInt
        }
        
        if let firstGenre = amsMatch.relationships?.genres?.data.first,
           let genreIdInt = Int64(firstGenre.id) {
            enrichedSong.genreStoreId = genreIdInt
        }
        
        if let firstGenreName = amsMatch.attributes.genreNames?.first {
            enrichedSong.genre = canonicalGenre(firstGenreName)
        }
        
        if let firstAlbum = amsMatch.relationships?.albums?.data.first,
           let albumIdInt = Int64(firstAlbum.id) {
            enrichedSong.playlistId = albumIdInt
        }
        
        let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
        let storefrontMap: [String: Int64] = [
            "us": 143441, "gb": 143444, "ca": 143455, "au": 143460,
            "de": 143443, "fr": 143442, "jp": 143462, "mx": 143468,
            "es": 143454, "it": 143450, "br": 143503, "kr": 143466,
            "cn": 143465, "in": 143467, "ru": 143469, "se": 143456,
            "nl": 143452, "no": 143457, "dk": 143458, "fi": 143447,
            "at": 143445, "ch": 143459, "be": 143446, "ie": 143449,
            "nz": 143461, "sg": 143464, "hk": 143463, "tw": 143470,
            "ar": 143505, "cl": 143483, "co": 143501, "pe": 143507,
            "ve": 143502, "ec": 143509, "cr": 143495, "pa": 143485,
            "do": 143508, "gt": 143504, "hn": 143510, "sv": 143506,
            "py": 143513, "uy": 143514, "bo": 143516, "ni": 143512,
            "pr": 143522, "ph": 143474, "th": 143475, "my": 143473,
            "id": 143476, "vn": 143471, "pk": 143477, "eg": 143516,
            "sa": 143479, "ae": 143481, "il": 143491, "za": 143472,
            "ng": 143561, "ke": 143529, "pt": 143453, "pl": 143478,
            "tr": 143480, "ua": 143492, "ro": 143487, "hu": 143482,
            "cz": 143489, "gr": 143448, "sk": 143496, "bg": 143526,
            "hr": 143494, "lt": 143520, "lv": 143519, "ee": 143518,
            "si": 143499, "lu": 143451, "mt": 143521
        ]
        enrichedSong.storefrontId = storefrontMap[region] ?? 143441
        
        if let artworkUrl = amsMatch.attributes.artwork?.artworkURL() {
            if let (data, _) = try? await URLSession.shared.data(from: artworkUrl) {
                enrichedSong.artworkData = data
            }
        }
        
        enrichedSong.genre = canonicalGenre(enrichedSong.genre)
        enrichedSong.richAppleMetadataFetched = true
        return enrichedSong
    }
}

struct iTunesSearchResult: Codable {
    let results: [iTunesSong]
}

struct iTunesSong: Codable, Identifiable {
    var id: Int { trackId ?? Int.random(in: 0...Int.max) }
    let trackId: Int?
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let primaryGenreName: String?
    let artistId: Int?
    let collectionId: Int?
    let releaseDate: String?
    let artworkUrl100: String?
    let trackNumber: Int?
    let trackCount: Int?
    let discNumber: Int?
    let discCount: Int?
}



extension SongMetadata {
    
    
    static func searchiTunes(query: String) async -> [iTunesSong] {
        let region = UserDefaults.standard.string(forKey: "storeRegion") ?? "US"
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(encodedQuery)&entity=song&limit=10&country=\(region)") else {
            return []
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let result = try JSONDecoder().decode(iTunesSearchResult.self, from: data)
            return result.results
        } catch {
            Logger.shared.log("[SongMetadata] iTunes search failed: \(error)")
            return []
        }
    }
    
    
    static func applyiTunesMatch(_ match: iTunesSong, to song: SongMetadata) async -> SongMetadata {
        var newSong = song
        
        if let t = match.trackName { newSong.title = t }
        if let a = match.artistName { newSong.artist = a }
        if let al = match.collectionName { newSong.album = al }
        if let g = match.primaryGenreName { newSong.genre = canonicalGenre(g) }
        if let aId = match.artistId { newSong.artistId = Int64(aId) }
        if let cId = match.collectionId { newSong.playlistId = Int64(cId) }
        if let tId = match.trackId { newSong.storeId = Int64(tId) }
        newSong.storefrontId = 143441 // Default to US Storefront for injected tracks
        
        newSong.trackNumber = match.trackNumber
        newSong.trackCount = match.trackCount
        newSong.discNumber = match.discNumber
        newSong.discCount = match.discCount
        
        if let dateStr = match.releaseDate {
            if let yearInt = Int(dateStr.prefix(4)) {
                newSong.year = yearInt
            }
            if let epoch = parseDateToEpoch(dateStr) {
                newSong.releaseDate = epoch
            }
        }
        
        
        if let artUrl = match.artworkUrl100 {
            
            let highResUrlString = artUrl.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")
            if let highResUrl = URL(string: highResUrlString),
               let (artData, _) = try? await URLSession.shared.data(from: highResUrl) {
                newSong.artworkData = artData
                Logger.shared.log("[SongMetadata] Updated artwork with iTunes High-Res version: \(artData.count) bytes")
            }
        }
        
        newSong.genre = canonicalGenre(newSong.genre)
        return newSong
    }

    
    static func enrichWithiTunesMetadata(_ song: SongMetadata) async -> SongMetadata {
        Logger.shared.log("[SongMetadata] Searching iTunes for: \(song.artist) - \(song.title)")
        
        let query = "\(song.artist) \(song.title)"
        let results = await searchiTunes(query: query)
        
        
        var bestMatch: iTunesSong?
        
        for match in results {
            guard let remoteArtist = match.artistName,
                  let remoteTitle = match.trackName else { continue }
            
            
            if song.artist != "Unknown Artist" {
                let localNorm = song.artist.lowercased().filter { !$0.isPunctuation }
                let remoteNorm = remoteArtist.lowercased().filter { !$0.isPunctuation }
                
                
                if localNorm.contains(remoteNorm) || remoteNorm.contains(localNorm) {
                    bestMatch = match
                    Logger.shared.log("[SongMetadata] ✓ Validated match: \(remoteTitle) by \(remoteArtist)")
                    break 
                } else {
                    Logger.shared.log("[SongMetadata] x Rejected match: \(remoteTitle) by \(remoteArtist) (Artist mismatch)")
                }
            } else {
                
                bestMatch = match
                break
            }
        }
        
        guard let match = bestMatch else {
            Logger.shared.log("[SongMetadata] No valid iTunes match found after filtering.")
            return song
        }
        
        var enrichedSong = await applyiTunesMatch(match, to: song)
        
        if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
            enrichedSong = await matchAppleMusicMetadata(enrichedSong)
        }
        
        return enrichedSong
    }
    
    static func enrichWithAppleMusicMetadata(_ song: SongMetadata) async -> SongMetadata {
        Logger.shared.log("[SongMetadata] Performing full Apple Music fetch for: \(song.artist) - \(song.title)")
        let query = "\(song.artist) \(song.title)"
        
        if let amsMatch = await AppleMusicAPI.shared.searchSong(query: query) {
            let enriched = await applyAppleMusicMatch(amsMatch, to: song)
            Logger.shared.log("[SongMetadata] ✓ Apple Music match: \(enriched.title) (\(enriched.storeId))")
            return enriched
        }
        
        return song
    }

    static func enrichWithExactAppleMusicTrack(_ song: SongMetadata, trackID: String) async -> SongMetadata {
        Logger.shared.log("[SongMetadata] Performing exact Apple Music fetch for track ID: \(trackID)")

        guard let amsMatch = await AppleMusicAPI.shared.fetchSong(id: trackID) else {
            Logger.shared.log("[SongMetadata] Exact Apple Music fetch failed for track ID: \(trackID)")
            return song
        }

        let enriched = await applyAppleMusicMatch(amsMatch, to: song)
        Logger.shared.log("[SongMetadata] ✓ Exact Apple Music match: \(enriched.title) (\(enriched.storeId))")
        return enriched
    }
    
    static func matchAppleMusicMetadata(_ song: SongMetadata) async -> SongMetadata {
        let query = "\(song.artist) \(song.title)"
        Logger.shared.log("[SongMetadata] 🔍 Shadow-searching Apple Music for rich metadata: '\(query)'")
        
        if let amsMatch = await AppleMusicAPI.shared.searchSong(query: query) {
            Logger.shared.log("[SongMetadata] ✨ Found Apple Music Server Match: \(amsMatch.attributes.name) by \(amsMatch.attributes.artistName) (ID: \(amsMatch.id))")
            return await applyAppleMusicMatch(amsMatch, to: song)
        } else {
            Logger.shared.log("[SongMetadata] ⚠️ No rich metadata match found on Apple Music for: '\(query)'")
        }
        
        return song
    }
}



struct DeezerSearchResult: Codable {
    let data: [DeezerSong]
}

struct DeezerSong: Codable, Identifiable {
    let id: Int
    let title: String
    let artist: DeezerReference
    let album: DeezerAlbumReference
    let duration: Int
    let explicit_lyrics: Bool?
    
    
    var trackName: String { title }
    var artistName: String { artist.name }
    var albumName: String { album.title }
    var artworkUrl: String { album.cover_xl }
}

struct DeezerReference: Codable {
    let name: String
}

struct DeezerAlbumReference: Codable {
    let title: String
    let cover_xl: String
}

struct DeezerTrackDetails: Codable {
    let track_position: Int?
    let disk_number: Int?
    let release_date: String? 
}



extension SongMetadata {
    
    
    static func searchDeezer(query: String) async -> [DeezerSong] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://api.deezer.com/search?q=\(encodedQuery)&limit=10") else {
            return []
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let result = try JSONDecoder().decode(DeezerSearchResult.self, from: data)
            return result.data
        } catch {
            Logger.shared.log("[SongMetadata] Deezer search failed: \(error)")
            return []
        }
    }
    
    static func fetchDeezerTrackDetails(id: Int) async -> DeezerTrackDetails? {
        guard let url = URL(string: "https://api.deezer.com/track/\(id)") else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(DeezerTrackDetails.self, from: data)
        } catch {
            Logger.shared.log("[SongMetadata] Failed to fetch Deezer track details: \(error)")
            return nil
        }
    }
    
    
    static func applyDeezerMatch(_ match: DeezerSong, to song: SongMetadata) async -> SongMetadata {
        var newSong = song
        
        newSong.title = match.title
        newSong.artist = match.artist.name
        newSong.album = match.album.title
        
        if let explicit = match.explicit_lyrics {
            newSong.explicitRating = explicit ? 1 : 0
        }
        
        newSong.durationMs = match.duration * 1000
        
        
        if let details = await fetchDeezerTrackDetails(id: match.id) {
            newSong.trackNumber = details.track_position
            newSong.discNumber = details.disk_number
            
            if let releaseDate = details.release_date {
                
                let components = releaseDate.split(separator: "-")
                if let yearStr = components.first, let yearInt = Int(yearStr) {
                    newSong.year = yearInt
                }
            }
            Logger.shared.log("[SongMetadata] Enhanced with Deezer details: Trk \(details.track_position ?? 0), Disc \(details.disk_number ?? 0), Year \(newSong.year)")
        }
        
        
        if let artUrl = URL(string: match.album.cover_xl),
           let (artData, _) = try? await URLSession.shared.data(from: artUrl) {
            newSong.artworkData = artData
            Logger.shared.log("[SongMetadata] Updated artwork with Deezer High-Res version: \(artData.count) bytes")
        }
        
        return newSong
    }
    
    static func enrichWithDeezerMetadata(_ song: SongMetadata) async -> SongMetadata {
        Logger.shared.log("[SongMetadata] Searching Deezer for: \(song.artist) - \(song.title)")
        let query = "\(song.artist) \(song.title)"
        let results = await searchDeezer(query: query)
        
        var enrichedSong = song
        if let firstMatch = results.first {
             Logger.shared.log("[SongMetadata] ✓ Deezer match: \(firstMatch.title) by \(firstMatch.artist.name)")
             enrichedSong = await applyDeezerMatch(firstMatch, to: song)
        }
        
        if UserDefaults.standard.bool(forKey: "appleRichMetadata") {
            enrichedSong = await matchAppleMusicMetadata(enrichedSong)
        }
        
        return enrichedSong
    }
}
// MARK: - Apple Music API
actor AppleMusicAPI {
    static let shared = AppleMusicAPI()
    private var cachedToken: String?
    
    func getToken() async -> String? {
        if let token = cachedToken { return token }
        
        Logger.shared.log("[AppleMusicAPI] Fetching token via URLSession...")
        
        guard let pageUrl = URL(string: "https://music.apple.com/us/browse") else { return nil }
        var pageRequest = URLRequest(url: pageUrl)
        pageRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        
        do {
            let (htmlData, _) = try await URLSession.shared.data(for: pageRequest)
            guard let html = String(data: htmlData, encoding: .utf8) else {
                Logger.shared.log("[AppleMusicAPI] ⚠️ Failed to decode HTML")
                return nil
            }
            
            let scriptPattern = #"src="([^"]*\/assets\/index[^"]*\.js)""#
            guard let scriptRegex = try? NSRegularExpression(pattern: scriptPattern),
                  let scriptMatch = scriptRegex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
                  let scriptRange = Range(scriptMatch.range(at: 1), in: html) else {
                Logger.shared.log("[AppleMusicAPI] ⚠️ No index JS bundle found in HTML")
                return nil
            }
            
            let jsPath = String(html[scriptRange])
            let jsUrlString = jsPath.hasPrefix("http") ? jsPath : "https://music.apple.com\(jsPath)"
            guard let jsUrl = URL(string: jsUrlString) else {
                Logger.shared.log("[AppleMusicAPI] ⚠️ Invalid JS URL: \(jsUrlString)")
                return nil
            }
            
            Logger.shared.log("[AppleMusicAPI] Found JS bundle: \(jsPath)")
            
            var jsRequest = URLRequest(url: jsUrl)
            jsRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            
            let (jsData, _) = try await URLSession.shared.data(for: jsRequest)
            guard let jsContent = String(data: jsData, encoding: .utf8) else {
                Logger.shared.log("[AppleMusicAPI] ⚠️ Failed to decode JS bundle")
                return nil
            }
            
            let tokenPattern = #"eyJhbGciOi[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#
            guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern),
                  let tokenMatch = tokenRegex.firstMatch(in: jsContent, range: NSRange(jsContent.startIndex..<jsContent.endIndex, in: jsContent)),
                  let tokenRange = Range(tokenMatch.range, in: jsContent) else {
                Logger.shared.log("[AppleMusicAPI] ⚠️ No token found in JS bundle")
                return nil
            }
            
            let token = String(jsContent[tokenRange])
            self.cachedToken = token
            Logger.shared.log("[AppleMusicAPI] ✅ Token fetched successfully via URLSession")
            return token
            
        } catch {
            Logger.shared.log("[AppleMusicAPI] ⚠️ Token fetch failed: \(error)")
            return nil
        }
    }
    
    struct AppleMusicSearchResponse: Codable {
        let results: AppleMusicSearchResults
    }
    
    struct AppleMusicSearchResults: Codable {
        let songs: AppleMusicSongsPage?
    }
    
    struct AppleMusicSongsPage: Codable {
        let data: [AppleMusicSong]
    }
    
    struct AppleMusicSong: Codable, Identifiable {
        let id: String
        let attributes: AppleMusicSongAttributes
        let relationships: AppleMusicSongRelationships?
    }
    
    struct AppleMusicSongAttributes: Codable {
        let name: String
        let artistName: String
        let albumName: String?
        let genreNames: [String]?
        let isrc: String?
        let contentRating: String?
        let releaseDate: String?
        let trackNumber: Int?
        let discNumber: Int?
        let durationInMillis: Int?
        let artwork: AppleMusicArtwork?
    }
    
    struct AppleMusicArtwork: Codable {
        let width: Int
        let height: Int
        let url: String
        
        func artworkURL(width w: Int = 1000, height h: Int = 1000) -> URL? {
            let processed = url.replacingOccurrences(of: "{w}", with: "\(w)")
                             .replacingOccurrences(of: "{h}", with: "\(h)")
            return URL(string: processed)
        }
    }
    
    struct AppleMusicSongRelationships: Codable {
        let albums: AppleMusicAlbumsPage?
        let artists: AppleMusicDataPage?
        let composers: AppleMusicDataPage?
        let genres: AppleMusicDataPage?
    }
    
    struct AppleMusicDataPage: Codable {
        let data: [AppleMusicReference]
    }
    
    struct AppleMusicReference: Codable {
        let id: String
    }
    
    struct AppleMusicAlbumsPage: Codable {
        let data: [AppleMusicAlbum]
    }
    
    struct AppleMusicAlbum: Codable {
        let id: String
        let attributes: AppleMusicAlbumAttributes
    }
    
    struct AppleMusicAlbumAttributes: Codable {
        let copyright: String?
        let releaseDate: String?
    }
    
    func searchSongs(query: String, limit: Int = 5) async -> [AppleMusicSong] {
        guard let token = await getToken() else { return [] }
        
        let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
        var comp = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(region)/search")!
        comp.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "include[songs]", value: "albums,artists,composers,genres")
        ]
        
        guard let url = comp.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let result = try JSONDecoder().decode(AppleMusicSearchResponse.self, from: data)
            return result.results.songs?.data ?? []
        } catch {
            Logger.shared.log("[AppleMusicAPI] Search failed: \(error)")
            return []
        }
    }

    func searchSong(query: String) async -> AppleMusicSong? {
        return await searchSongs(query: query, limit: 1).first
    }

    func fetchSong(id: String) async -> AppleMusicSong? {
        guard let token = await getToken() else { return nil }

        let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
        guard let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(region)/songs/\(id)?include=albums,artists,composers,genres") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let result = try JSONDecoder().decode(AppleMusicDirectSongResponse.self, from: data)
            return result.data.first
        } catch {
            Logger.shared.log("[AppleMusicAPI] Direct song fetch failed: \(error)")
            return nil
        }
    }
}

private struct AppleMusicDirectSongResponse: Codable {
    let data: [AppleMusicAPI.AppleMusicSong]
}

extension SongMetadata {
    static func parseDateToEpoch(_ dateStr: String) -> Int? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "yyyy-MM-dd",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy"
        ]
        for fmt in formats {
            df.dateFormat = fmt
            if let date = df.date(from: dateStr) {
                return Int(date.timeIntervalSinceReferenceDate)
            }
        }
        return nil
    }
}
