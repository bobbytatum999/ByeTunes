import SwiftUI

struct iTunesSearchSheet: View {
    @Binding var song: SongMetadata
    @Binding var isPresented: Bool
    
    @AppStorage("metadataSource") private var metadataSource = "local"
    
    @State private var searchQuery: String = ""
    @State private var itunesResults: [iTunesSong] = []
    @State private var deezerResults: [DeezerSong] = []
    @State private var appleResults: [AppleMusicAPI.AppleMusicSong] = []
    @State private var youtubeResults: [YouTubeMetadataCandidate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    @State private var activeSource: String = "itunes"
    
    private var sourceDisplayName: String {
        switch activeSource {
        case "deezer": return "Deezer"
        case "apple": return "Apple Music"
        case "youtube": return "YouTube"
        default: return "iTunes (\(UserDefaults.standard.string(forKey: "storeRegion") ?? "US"))"
        }
    }
    
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text("Select Match")
                        .font(.system(size: 24, weight: .bold))
                    
                    if metadataSource == "local" || metadataSource == "all" {
                        Menu {
                            Button("iTunes") { activeSource = "itunes" }
                            Button("Deezer") { activeSource = "deezer" }
                            Button("Apple Music") { activeSource = "apple" }
                            Button("YouTube") { activeSource = "youtube" }
                        } label: {
                            HStack(spacing: 4) {
                                Text(sourceDisplayName)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .font(.caption2.weight(.bold))
                            .foregroundColor(activeSource == "deezer" ? .red : (activeSource == "youtube" ? .red : .accentColor))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .stroke(activeSource == "deezer" ? Color.red.opacity(0.3) : (activeSource == "youtube" ? Color.red.opacity(0.3) : Color.accentColor.opacity(0.3)), lineWidth: 1)
                            )
                        }
                        .offset(y: -2)
                    } else {
                        Text(sourceDisplayName)
                            .font(.caption2.weight(.bold))
                            .foregroundColor(activeSource == "deezer" ? .red : (activeSource == "youtube" ? .red : .accentColor))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .stroke(activeSource == "deezer" ? Color.red.opacity(0.3) : (activeSource == "youtube" ? Color.red.opacity(0.3) : Color.accentColor.opacity(0.3)), lineWidth: 1)
                            )
                            .offset(y: -2)
                    }
                    
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .padding([.top, .horizontal], 20)
                .padding(.bottom, 10)
                
                
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search \(sourceDisplayName)...", text: $searchQuery)
                        .submitLabel(.search)
                        .onSubmit {
                            performSearch()
                        }
                    
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                
                
                if isLoading {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Searching \(sourceDisplayName)...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if let error = errorMessage {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    Spacer()
                    Spacer()
                } else if resultsForActiveSource.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 48))
                            .foregroundColor(Color(.systemGray4))
                        Text("No matching songs found")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Try a different search term")
                            .font(.caption)
                            .foregroundColor(Color(uiColor: .tertiaryLabel))
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if activeSource == "deezer" {
                                ForEach(Array(deezerResults.enumerated()), id: \.element.id) { index, match in
                                    VStack(spacing: 0) {
                                        Button {
                                            applyDeezerMatch(match)
                                        } label: {
                                            DeezerRow(match: match)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        
                                        if index < deezerResults.count - 1 {
                                            Divider().padding(.leading, 80)
                                        }
                                    }
                                }
                            } else if activeSource == "apple" {
                                ForEach(Array(appleResults.enumerated()), id: \.element.id) { index, match in
                                    VStack(spacing: 0) {
                                        Button {
                                            applyAppleMatch(match)
                                        } label: {
                                            AppleMusicRow(match: match)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        
                                        if index < appleResults.count - 1 {
                                            Divider().padding(.leading, 80)
                                        }
                                    }
                                }
                            } else if activeSource == "youtube" {
                                ForEach(Array(youtubeResults.enumerated()), id: \.element.videoID) { index, match in
                                    VStack(spacing: 0) {
                                        Button {
                                            applyYouTubeMatch(match)
                                        } label: {
                                            YouTubeRow(match: match)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        
                                        if index < youtubeResults.count - 1 {
                                            Divider().padding(.leading, 80)
                                        }
                                    }
                                }
                            } else {
                                ForEach(Array(itunesResults.enumerated()), id: \.element.trackId) { index, match in
                                    VStack(spacing: 0) {
                                        Button {
                                            applyItunesMatch(match)
                                        } label: {
                                            iTunesRow(match: match)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        
                                        if index < itunesResults.count - 1 {
                                            Divider().padding(.leading, 80)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .onAppear {
            if metadataSource == "local" || metadataSource == "all" {
                activeSource = "itunes"
            } else {
                activeSource = metadataSource
            }
            
            if searchQuery.isEmpty {
                searchQuery = "\(song.artist) \(song.title)"
                performSearch()
            }
        }
        .onChange(of: activeSource) { _ in
            itunesResults = []
            deezerResults = []
            appleResults = []
            youtubeResults = []
            performSearch()
        }
    }
    
    private var resultsForActiveSource: [Any] {
        switch activeSource {
        case "deezer": return deezerResults
        case "apple": return appleResults
        case "youtube": return youtubeResults
        default: return itunesResults
        }
    }
    
    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        
        Task {
            if activeSource == "deezer" {
                 let results = await SongMetadata.searchDeezer(query: searchQuery)
                 await MainActor.run {
                     self.deezerResults = results
                     self.isLoading = false
                 }
            } else if activeSource == "apple" {
                 let results = await AppleMusicAPI.shared.searchSongs(query: searchQuery, limit: 10)
                 await MainActor.run {
                     self.appleResults = results
                     self.isLoading = false
                 }
            } else if activeSource == "youtube" {
                 let results = await MetadataProvider.searchYouTubeForMetadata(query: searchQuery, limit: 10)
                 await MainActor.run {
                     self.youtubeResults = results
                     self.isLoading = false
                 }
            } else {
                 let results = await SongMetadata.searchiTunes(query: searchQuery)
                 await MainActor.run {
                     self.itunesResults = results
                     self.isLoading = false
                 }
            }
        }
    }
    
    private func applyItunesMatch(_ match: iTunesSong) {
        isLoading = true
        Task {
            let updatedSong = await SongMetadata.applyiTunesMatch(match, to: song)
            await MainActor.run {
                self.song = updatedSong
                self.isLoading = false
                self.isPresented = false
            }
        }
    }
    
    private func applyDeezerMatch(_ match: DeezerSong) {
        isLoading = true
        Task {
            let updatedSong = await SongMetadata.applyDeezerMatch(match, to: song)
            await MainActor.run {
                self.song = updatedSong
                self.isLoading = false
                self.isPresented = false
            }
        }
    }
    
    private func applyAppleMatch(_ match: AppleMusicAPI.AppleMusicSong) {
        isLoading = true
        Task {
            let updatedSong = await SongMetadata.applyAppleMusicMatch(match, to: song)
            
            await MainActor.run {
                self.song = updatedSong
                self.isLoading = false
                self.isPresented = false
            }
        }
    }
    
    private func applyYouTubeMatch(_ match: YouTubeMetadataCandidate) {
        isLoading = true
        Task {
            var updatedSong = song
            let parsed = MetadataProvider.normalizeYouTubeTitle(match.title, channel: match.channelTitle)
            updatedSong.title = parsed.title
            updatedSong.artist = parsed.artist
            updatedSong.album = parsed.album
            updatedSong.youtubeVideoID = match.videoID
            if let thumbURL = match.thumbnailURL,
               let (data, _) = try? await URLSession.shared.data(from: thumbURL) {
                updatedSong.artworkData = data
            }
            if let duration = match.durationMs, duration > 0 {
                updatedSong.durationMs = duration
            }
            await MainActor.run {
                self.song = updatedSong
                self.isLoading = false
                self.isPresented = false
            }
        }
    }
}


struct iTunesRow: View {
    let match: iTunesSong
    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: match.artworkUrl100 ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(uiColor: .systemGray5)
                    .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
            }
            .frame(width: 48, height: 48).cornerRadius(6)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(match.trackName ?? "Unknown Title").font(.body).foregroundColor(.primary).lineLimit(1)
                Text(match.artistName ?? "Unknown Artist").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    if let album = match.collectionName { Text(album).lineLimit(1) }
                    if let year = match.releaseDate?.prefix(4) { Text("• \(String(year))") }
                }.font(.caption).foregroundColor(.secondary.opacity(0.8))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct DeezerRow: View {
    let match: DeezerSong
    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: match.album.cover_xl)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(uiColor: .systemGray5)
                    .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
            }
            .frame(width: 48, height: 48).cornerRadius(6)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(match.title).font(.body).foregroundColor(.primary).lineLimit(1)
                Text(match.artist.name).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                Text(match.album.title).font(.caption).foregroundColor(.secondary.opacity(0.8)).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct AppleMusicRow: View {
    let match: AppleMusicAPI.AppleMusicSong
    var body: some View {
        HStack(spacing: 14) {
            if let artwork = match.attributes.artwork {
                AsyncImage(url: artwork.artworkURL(width: 200, height: 200)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color(uiColor: .systemGray5)
                        .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                }
                .frame(width: 48, height: 48).cornerRadius(6)
            } else {
                Color(uiColor: .systemGray5)
                    .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                    .frame(width: 48, height: 48).cornerRadius(6)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(match.attributes.name).font(.body).foregroundColor(.primary).lineLimit(1)
                Text(match.attributes.artistName).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                if let album = match.attributes.albumName {
                    Text(album).font(.caption).foregroundColor(.secondary.opacity(0.8)).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct YouTubeRow: View {
    let match: YouTubeMetadataCandidate
    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: match.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(uiColor: .systemGray5)
                    .overlay(Image(systemName: "play.rectangle").foregroundColor(.secondary))
            }
            .frame(width: 48, height: 48).cornerRadius(6)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(match.title).font(.body).foregroundColor(.primary).lineLimit(1)
                Text(match.channelTitle).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                if let durationMs = match.durationMs, durationMs > 0 {
                    let seconds = durationMs / 1000
                    let minutes = seconds / 60
                    let remainingSeconds = seconds % 60
                    Text("\(minutes):\(String(format: "%02d", remainingSeconds))")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
