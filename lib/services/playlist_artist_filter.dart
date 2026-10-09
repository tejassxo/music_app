import 'fuzzy_search_service.dart';

/// Representation of playlist search results distinguishing artist matches from title matches
class PlaylistSearchResult {
  final List<int> matchedIndices;
  final String? matchedArtist;
  final bool isArtistSearch;

  const PlaylistSearchResult({
    required this.matchedIndices,
    this.matchedArtist,
    this.isArtistSearch = false,
  });
}

/// Helper class for artist item and count
class ArtistSongCount {
  final String name;
  final int count;

  const ArtistSongCount({required this.name, required this.count});
}

/// Industrial-strength Artist Extractor, Normalizer & Matcher for Custom and Imported Playlists.
class PlaylistArtistFilter {
  PlaylistArtistFilter._();

  /// Normalizes a string by lowercasing, stripping punctuation, and collapsing whitespace.
  static String normalize(String text) {
    if (text.isEmpty) return '';
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Known Record Labels, media houses, and channels that should not be treated as artists
  static const Set<String> _labelNoise = {
    't-series',
    'tseries',
    'aditya music',
    'sony music',
    'zee music',
    'lahari music',
    'speed audio',
    'tips official',
    'tips',
    'saregama',
    'yrf',
    'think music',
    'vevo',
    'records',
    'entertainment',
    'music',
    'official',
    'channel',
    'audio',
    'soundtracks',
    'company',
    'shreyas media',
    'shreyas',
    'nik studios',
    'abhishek pictures',
    'sun tv',
    'sun pictures',
    'geetha arts',
    'mythri movie makers',
    'mango music',
    'madhura audio',
    'annapurna studios',
    'sithara entertainments',
    'haarikahassine',
    'aditya',
    'adityamusic',
    'aditya dev',
    'filmnagar',
    'media',
    't series',
    't-series telugu',
    'sony music south',
    'zee music south',
  };

  /// Common artist aliases and variations across Indian and international music
  static final Map<String, List<String>> _artistAliases = {
    'dsp': ['devi sri prasad', 'devi sri', 'rockstar dsp'],
    'devi sri prasad': ['dsp', 'devi sri', 'rockstar dsp'],
    'spb': [
      's p balasubrahmanyam',
      's. p. balasubrahmanyam',
      'balasubrahmanyam',
      's.p.b.',
      'sp balasubrahmanyam',
      's p balasubramaniam',
      'balasubramaniam',
    ],
    'balasubrahmanyam': [
      'spb',
      's p balasubrahmanyam',
      's p balasubramaniam',
      'balasubramaniam',
    ],
    's p balasubrahmanyam': [
      'spb',
      'balasubrahmanyam',
      's p balasubramaniam',
      'balasubramaniam',
    ],
    'balasubramaniam': [
      'spb',
      's p balasubrahmanyam',
      's p balasubramaniam',
      'balasubrahmanyam',
    ],
    's p balasubramaniam': [
      'spb',
      'balasubrahmanyam',
      's p balasubrahmanyam',
      'balasubramaniam',
    ],
    'arr': ['a r rahman', 'a. r. rahman', 'ar rahman', 'rahman', 'a.r. rahman'],
    'ar rahman': ['arr', 'a r rahman', 'a.r. rahman', 'rahman'],
    'rahman': ['arr', 'ar rahman', 'a.r. rahman', 'a r rahman'],
    'anirudh': ['anirudh ravichander'],
    'anirudh ravichander': ['anirudh'],
    'sid': ['sid sriram'],
    'sid sriram': ['sid'],
    'arijit': ['arijit singh'],
    'arijit singh': ['arijit'],
    'shreya': ['shreya ghoshal'],
    'shreya ghoshal': ['shreya'],
    'thaman': ['s thaman', 'thaman s'],
    'thaman s': ['thaman', 's thaman'],
    'keeravani': [
      'm m keeravani',
      'm.m. keeravani',
      'm m keeravaani',
      'keeravaani',
    ],
    'm m keeravani': ['keeravani', 'keeravaani'],
    'yuvan': ['yuvan shankar raja'],
    'yuvan shankar raja': ['yuvan'],
    'santhosh': ['santhosh narayanan'],
    'santhosh narayanan': ['santhosh'],
    'harris': ['harris jayaraj'],
    'harris jayaraj': ['harris'],
    'chithra': ['k s chithra', 'k.s. chithra'],
    'ilayaraja': ['ilaiyaraaja', 'ilayaraja', 'ilayaraja sir'],
    'ilaiyaraaja': ['ilayaraja'],
    'pritam': ['pritam chakraborty'],
    'badshah': ['badshah'],
    'shilpa': ['shilpa rao'],
    'shilpa rao': ['shilpa'],
    'jonita': ['jonita gandhi'],
    'jonita gandhi': ['jonita'],
  };

  /// Extracts clean distinct artist names from a song map
  static List<String> extractArtistsFromSong(Map<String, dynamic> song) {
    final artists = <String>{};
    final rawAuthor = (song['author'] as String? ?? '').trim();
    final rawTitle = (song['title'] as String? ?? '').trim();
    final rawArtist = (song['artist'] as String? ?? '').trim();

    void addCandidate(String candidate) {
      var trimmed = candidate.trim();
      // Remove bracketed suffixes like (singer), [composer]
      trimmed = trimmed.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), '').trim();
      if (trimmed.isEmpty || trimmed.length < 2) return;
      final norm = normalize(trimmed);
      if (norm.isEmpty) return;

      // Check if record label or channel noise
      for (final label in _labelNoise) {
        if (norm == label ||
            norm.startsWith('$label ') ||
            norm.endsWith(' $label')) {
          return;
        }
      }

      // Reject non-artist words, song descriptors, and media tags
      final words = norm.split(' ');
      if (words.contains('song') ||
          words.contains('songs') ||
          words.contains('track') ||
          words.contains('tracks') ||
          words.contains('video') ||
          words.contains('audio') ||
          words.contains('jukebox') ||
          words.contains('mashup') ||
          words.contains('soundtrack') ||
          words.contains('ost') ||
          words.contains('theme') ||
          words.contains('promo') ||
          words.contains('trailer') ||
          words.contains('teaser') ||
          words.contains('official') ||
          words.contains('full') ||
          words.contains('lyric') ||
          words.contains('lyrics') ||
          norm.contains('full video') ||
          norm.contains('lyric video')) {
        return;
      }

      artists.add(trimmed);
    }

    // 1. Direct 'artist' field from metadata
    if (rawArtist.isNotEmpty) {
      final parts = rawArtist.split(
        RegExp(
          r'[,;&/]|(?:\s+feat\.?\s+)|\s+ft\.?\s+|\s+with\s+|\s+and\s+',
          caseSensitive: false,
        ),
      );
      for (final p in parts) {
        addCandidate(p);
      }
    }

    // 2. Author field
    if (rawAuthor.isNotEmpty) {
      final parts = rawAuthor.split(
        RegExp(
          r'[,;&/]|(?:\s+feat\.?\s+)|\s+ft\.?\s+|\s+with\s+|\s+and\s+',
          caseSensitive: false,
        ),
      );
      for (final p in parts) {
        addCandidate(p);
      }
    }

    // 3. Extract from title when delimited by standard separators (| or -)
    if (rawTitle.isNotEmpty) {
      // First check for explicit featuring tags e.g. "feat. Shilpa Rao", "ft. Arijit Singh"
      final featMatches = RegExp(
        r'(?:feat\.?|ft\.?)\s+([^\)\]\|,]+)',
        caseSensitive: false,
      ).allMatches(rawTitle);
      for (final m in featMatches) {
        final featArtist = m.group(1);
        if (featArtist != null) {
          addCandidate(featArtist);
        }
      }

      // If title has pipe '|', segments after the first pipe are artist/credit metadata
      if (rawTitle.contains('|')) {
        final segments = rawTitle.split('|').sublist(1);
        for (final segment in segments) {
          var cleanSeg = segment.trim();
          cleanSeg = cleanSeg
              .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
              .trim();
          if (cleanSeg.length >= 2) {
            final subparts = cleanSeg.split(
              RegExp(
                r'[,;&/]|(?:\s+feat\.?\s+)|\s+ft\.?\s+|\s+with\s+',
                caseSensitive: false,
              ),
            );
            for (final sp in subparts) {
              addCandidate(sp);
            }
          }
        }
      } else {
        final parts = rawTitle.split(RegExp(r'\s*[–—/]\s*|\s+-\s+'));
        for (int i = 1; i < parts.length; i++) {
          var segment = parts[i].trim();
          segment = segment
              .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
              .trim();
          if (segment.length >= 2) {
            final subparts = segment.split(
              RegExp(
                r'[,;&]|(?:\s+feat\.?\s+)|\s+ft\.?\s+|\s+with\s+',
                caseSensitive: false,
              ),
            );
            for (final sp in subparts) {
              addCandidate(sp);
            }
          }
        }
      }
    }

    return artists.toList();
  }

  /// Determines whether a search query matches an artist name
  static bool isArtistMatch(String query, String candidateArtist) {
    final cleanQ = normalize(query);
    final cleanA = normalize(candidateArtist);
    if (cleanQ.isEmpty || cleanA.isEmpty) return false;

    // Exact match
    if (cleanQ == cleanA) return true;

    // Substring match if query has at least 3 characters
    if (cleanQ.length >= 3) {
      if (cleanA.contains(cleanQ)) return true;
      if (cleanQ.contains(cleanA) && cleanA.length >= 3) return true;
    }

    // Token-level word boundary match (e.g. "Sid" matches "Sid Sriram")
    final artistWords = cleanA.split(' ');
    final queryWords = cleanQ.split(' ');
    for (final qWord in queryWords) {
      if (qWord.length < 2) continue;
      for (final aWord in artistWords) {
        if (aWord == qWord || (qWord.length >= 3 && aWord.startsWith(qWord))) {
          return true;
        }
      }
    }

    // Known artist aliases (e.g. "dsp" <-> "devi sri prasad", "arr" <-> "ar rahman")
    if (_artistAliases.containsKey(cleanQ)) {
      for (final alias in _artistAliases[cleanQ]!) {
        final cleanAlias = normalize(alias);
        if (cleanA == cleanAlias ||
            cleanA.contains(cleanAlias) ||
            cleanAlias.contains(cleanA)) {
          return true;
        }
      }
    }

    return false;
  }

  /// Checks if the query matches an artist present in this playlist.
  /// Returns the matched artist name, or null if no artist in this playlist matches.
  static String? findMatchingArtistInPlaylist(
    List<Map<String, dynamic>> songs,
    String query,
  ) {
    final cleanQ = normalize(query);
    if (cleanQ.length < 2) return null;

    for (final song in songs) {
      final artists = extractArtistsFromSong(song);
      for (final artist in artists) {
        if (isArtistMatch(query, artist)) {
          return artist;
        }
      }
    }
    return null;
  }

  /// Returns indices of all songs in the playlist that belong to the specified artist
  static List<int> filterSongIndicesByArtist(
    List<Map<String, dynamic>> songs,
    String artistOrQuery,
  ) {
    final matchingIndices = <int>[];
    for (int i = 0; i < songs.length; i++) {
      final song = songs[i];
      final artists = extractArtistsFromSong(song);
      bool matched = false;
      for (final a in artists) {
        if (isArtistMatch(artistOrQuery, a)) {
          matched = true;
          break;
        }
      }
      if (matched) {
        matchingIndices.add(i);
      }
    }
    return matchingIndices;
  }

  /// Extracts top distinct artists present in this playlist along with song counts
  static List<ArtistSongCount> getTopArtistsWithCounts(
    List<Map<String, dynamic>> songs, {
    int limit = 10,
  }) {
    final counts = <String, int>{};
    final displayNames = <String, String>{};

    for (final song in songs) {
      final artists = extractArtistsFromSong(song);
      for (final a in artists) {
        final norm = normalize(a);
        if (norm.length < 2) continue;
        counts[norm] = (counts[norm] ?? 0) + 1;
        displayNames.putIfAbsent(norm, () => a);
      }
    }

    final list = counts.entries.map((e) {
      return ArtistSongCount(
        name: displayNames[e.key] ?? e.key,
        count: e.value,
      );
    }).toList();

    // Sort descending by count
    list.sort((a, b) => b.count.compareTo(a.count));
    return list.take(limit).toList();
  }

  /// Primary search engine for custom/imported playlists.
  /// If query matches an artist present in the playlist, it returns ALL songs of ONLY that particular artist.
  /// Otherwise, it performs word-boundary title & artist matching.
  static PlaylistSearchResult searchPlaylist({
    required List<Map<String, dynamic>> songs,
    required String query,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const PlaylistSearchResult(matchedIndices: []);
    }

    final cleanQ = normalize(trimmed);
    if (cleanQ.isEmpty) {
      return const PlaylistSearchResult(matchedIndices: []);
    }

    // Step 1: Detect if query is an artist present in this playlist
    final matchedArtist = findMatchingArtistInPlaylist(songs, trimmed);
    if (matchedArtist != null) {
      final artistIndices = filterSongIndicesByArtist(songs, trimmed);
      if (artistIndices.isNotEmpty) {
        return PlaylistSearchResult(
          matchedIndices: artistIndices,
          matchedArtist: matchedArtist,
          isArtistSearch: true,
        );
      }
    }

    // Step 2: Song Title & Author search
    final matchedIndices = <int>[];
    final queryLower = trimmed.toLowerCase();

    for (int i = 0; i < songs.length; i++) {
      final song = songs[i];
      final title = (song['title'] as String? ?? '').toLowerCase();
      final author = (song['author'] as String? ?? '').toLowerCase();
      final normTitle = normalize(title);

      bool titleMatches = false;
      if (cleanQ.length <= 3) {
        final words = normTitle.split(' ');
        titleMatches = words.any(
          (w) => w == cleanQ || (cleanQ.length >= 3 && w.startsWith(cleanQ)),
        );
      } else {
        titleMatches = title.contains(queryLower) || normTitle.contains(cleanQ);
      }

      final authorMatches =
          author.contains(queryLower) || normalize(author).contains(cleanQ);

      if (titleMatches || authorMatches) {
        matchedIndices.add(i);
      }
    }

    // Step 3: Typo-tolerant fallback powered by FuzzySearchService (Bitap algorithm)
    if (matchedIndices.isEmpty && cleanQ.length >= 3) {
      final fuzzyMatches = FuzzySearchService.searchTrackMaps(songs, trimmed);
      if (fuzzyMatches.isNotEmpty) {
        final fuzzyIds = fuzzyMatches.map((m) => m['id']).toSet();
        for (int i = 0; i < songs.length; i++) {
          final id = songs[i]['id'];
          if (id != null && fuzzyIds.contains(id)) {
            matchedIndices.add(i);
          }
        }
      }
    }

    return PlaylistSearchResult(
      matchedIndices: matchedIndices,
      matchedArtist: null,
      isArtistSearch: false,
    );
  }
}
