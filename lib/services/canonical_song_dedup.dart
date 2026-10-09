import 'dart:math';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'lyrics_transliteration_service.dart';

/// Industrial-grade Canonical Song Normalizer & Deduplicator.
///
/// Handles noisy YouTube titles with movie names, actors, skits, and 4K tags,
/// matching them accurately against clean JioSaavn and YouTube Music studio tracks.
class CanonicalSongDedup {
  CanonicalSongDedup._();

  // Noise regex for titles
  static final RegExp _bracketNoise = RegExp(r'\([^)]*\)|\[[^\]]*\]');
  static final RegExp _featNoise = RegExp(
    r'\b(?:feat|ft)\.?(?:\s+|$).*$',
    caseSensitive: false,
  );
  static final RegExp _featPattern = RegExp(
    r'(?:[\(\[]\s*)?\b(?:feat|ft|featuring)\.?\s+([^\)\]\|,]+)(?:\s*[\)\]])?|'
    r'[\(\[]\s*with\s+([^\)\]\|,]+)\s*[\)\]]',
    caseSensitive: false,
  );

  /// Detects whether a title or artist credit indicates a featured collaboration.
  static bool isFeaturedTrack(String title, [String? artist]) {
    if (title.isNotEmpty && _featPattern.hasMatch(title)) return true;
    if (artist != null && artist.isNotEmpty && _featPattern.hasMatch(artist)) {
      return true;
    }
    return false;
  }

  /// Extracts the primary featured artist from title or artist credit.
  static String? extractFeaturedArtist(String title, [String? artist]) {
    if (title.isNotEmpty) {
      final mTitle = _featPattern.firstMatch(title);
      if (mTitle != null) {
        final feat = (mTitle.group(1) ?? mTitle.group(2))?.trim();
        if (feat != null && feat.isNotEmpty) return feat;
      }
    }
    if (artist != null && artist.isNotEmpty) {
      final mArtist = _featPattern.firstMatch(artist);
      if (mArtist != null) {
        final feat = (mArtist.group(1) ?? mArtist.group(2))?.trim();
        if (feat != null && feat.isNotEmpty) return feat;
      }
    }
    return null;
  }

  /// Extracts clean core base title without featured tags or bracket noise.
  static String extractBaseTitle(String title) {
    if (title.trim().isEmpty) return '';
    var s = title.replaceAll(_featPattern, ' ');
    return cleanTitle(s);
  }

  static final RegExp _videoNoiseWords = RegExp(
    r'\b(official\s+video|official\s+music\s+video|official\s+lyric\s+video|lyric\s+video|'
    r'full\s+video\s+song|video\s+song|full\s+song|full\s+audio|audio\s+song|lyrics|'
    r'lyrical|4k\s+video|hd\s+video|4k|8k|hd|1080p|remix|mashup|status\s+video|status|'
    r'ringtone|dialogue|extended\s+version|original\s+soundtrack|ost)\b',
    caseSensitive: false,
  );

  // Non-music video noise patterns (speeches, interviews, launch events, cricket, sketches, jukeboxes, amateur covers, reels, wedding rituals, DJ mashups, workout/gym tracks)
  static final RegExp _nonMusicTitleNoise = RegExp(
    r'\b(speech|speech\s*@|press\s+meet|success\s+meet|launch\s+event|song\s+launch|audio\s+launch|'
    r'pre\s+release|trailer|teaser|glimpse|promo|first\s+look|motion\s+poster|title\s+reveal|'
    r'interview|talk\s+show|podcast|episode|review|reaction|reacting|behind\s+the\s+scenes|making\s+of|bts|'
    r'dances?\s+to|dance\s+performance|dance\s+cover|dance\s+video|stage\s+performance|performance\s+video|'
    r'status\s+video|whatsapp\s+status|cricket|ipl|match\s+highlights|trophy|shreyas\s+iyer|'
    r'full\s+movie|movie\s+scene|comedy\s+scene|action\s+scene|fight\s+scene|climax\s+scene|scenes|comedy\s+scenes|'
    r'ringtone|bgm\s+only|shorts|#shorts|shorts\s+video|reels?|tiktok|troll|parody|spoof|'
    r'jukebox|all\s+songs|audio\s+jukebox|video\s+jukebox|full\s+album|mega\s+jukebox|'
    r'slowed\s*(?:\+|\band\b)?\s*reverb|speed\s*up|sped\s*up|nightcore|8d\s+audio|bass\s+boosted|'
    r'acoustic\s+cover|guitar\s+cover|piano\s+cover|flute\s+cover|violin\s+cover|vocal\s+cover|cover\s+song|cover\s+version|cover\s+classics|female\s+cover|male\s+cover|'
    r'instrumental|karaoke|oye\s+lalii|'
    r'tabata|power\s+music|workout\s+(?:mix|music|version|track)?|fitness\s+beats|gym\s+(?:music|mix|workout)|'
    r'carnatic\s+mix|lo-?fi\s+mix|'
    r'varmala|vidhi|ceremony|wedding\s+music|shaadi|mehendi|sangeet|sarangi\s+tabla|mangal\s+sutra|kanyadaan|shehnai|band\s+baaja|dulhan|'
    r'dj\s+\w+|dj\s+mix|dj\s+remix|mashup|mash\s+up|club\s+mix|remix|'
    r'making\s+video|bloopers|deleted\s+scenes?|'
    r'exclusive\s+interview|success\s+celebrations?|song\s+teaser)\b',
    caseSensitive: false,
  );

  static final RegExp _nonMusicAuthorNoise = RegExp(
    r'\b(media|news|tv|filmnagar|events|buzz|sports|daily|cinema\s+news|vlogs?|cricket|gaming|memes?|creations?|edits?|dj\s+\w+|remix\s+hub|wedding|ceremony|oye\s+lalii|cover\s+classics|the\s+covers|the\s+hit\s+crew|party\s+hits\s+band|tabata|power\s+music|fitness\s+beats|workout|luxebeats|zzang|sweet\s+strings)\b',
    caseSensitive: false,
  );

  static final RegExp _punctuation = RegExp(r'[^a-zA-Z0-9\s]');
  static final RegExp _whitespace = RegExp(r'\s+');

  // Record label, media company and noise words in artist names
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
    'gr lyrics',
    'lyrics',
    'lyrical',
    'filmnagar',
    'media',
    'news',
    'tv',
  };

  /// Common stopwords ignored during token set comparison
  static const Set<String> _stopwords = {
    'the',
    'a',
    'an',
    'and',
    'from',
    'in',
    'on',
    'at',
    'to',
    'for',
    'of',
    'with',
    'by',
    'song',
    'track',
    'movie',
    'album',
  };

  /// Cleans duplicate repeated bracket descriptors e.g. "Perfect (Acoustic) (Acoustic)" -> "Perfect (Acoustic)"
  static String deduplicateRepeatedTokens(String text) {
    if (text.isEmpty) return text;
    var result = text;
    // Deduplicate identical consecutive parenthetical or bracketed groups e.g. (Acoustic) (Acoustic)
    final bracketPattern = RegExp(
      r'(\([^\)]+\)|\[[^\]]+\])(?:\s+\1)+',
      caseSensitive: false,
    );
    result = result.replaceAllMapped(bracketPattern, (m) => m.group(1)!);

    // Deduplicate repeated identical words in parentheses: (Acoustic Acoustic) -> (Acoustic)
    final innerWordPattern = RegExp(
      r'\(\s*(\b\w+\b)(?:\s+\1)+\s*\)',
      caseSensitive: false,
    );
    result = result.replaceAllMapped(
      innerWordPattern,
      (m) => '(${m.group(1)})',
    );

    // Clean multiple identical tags like (Acoustic) ... (Acoustic)
    final tags = RegExp(
      r'\(([^\)]+)\)',
    ).allMatches(result).map((m) => m.group(1)!.trim().toLowerCase()).toList();
    if (tags.length > 1 && tags.toSet().length < tags.length) {
      final seenTag = <String>{};
      result = result.replaceAllMapped(RegExp(r'\s*\(([^\)]+)\)'), (m) {
        final tag = m.group(1)!.trim().toLowerCase();
        if (seenTag.contains(tag)) {
          return '';
        }
        seenTag.add(tag);
        return ' (${m.group(1)!.trim()})';
      });
    }

    return result.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Cleans raw YouTube and streaming titles for display in the UI,
  /// stripping bracketed video tags (e.g. "[Official Video]", "(Official Music Video)"),
  /// redundant artist prefixes (e.g. "Ed Sheeran - Shivers" -> "Shivers"),
  /// and video metadata noise while preserving genuine song subtitle descriptors.
  static String sanitizeDisplayTitle(String rawTitle, {String? artist}) {
    if (rawTitle.trim().isEmpty) return '';
    var s = rawTitle.trim();

    // 1. Remove bracketed video / quality / lyrics tags
    s = s.replaceAll(
      RegExp(
        r'\[\s*(?:official\s+(?:music\s+)?video|official\s+audio|official\s+lyric\s+video|lyric\s+video|visualizer|lyrics|hd|4k(?:\s+hdr)?|audio|video)\s*\]',
        caseSensitive: false,
      ),
      '',
    );
    s = s.replaceAll(
      RegExp(
        r'\(\s*(?:official\s+(?:music\s+)?video|official\s+audio|official\s+lyric\s+video|lyric\s+video|visualizer|lyrics|audio|video)\s*\)',
        caseSensitive: false,
      ),
      '',
    );

    // 2. Strip video suffix bars: e.g. "Song Name | Official Music Video" or "Song Name - Official Video"
    s = s.replaceAll(
      RegExp(
        r'\s*(?:[|:–—/]|-\s*)\s*(?:official\s+(?:music\s+)?video|official\s+audio|official\s+lyric\s+video|lyric\s+video|lyrics|visualizer)\s*$',
        caseSensitive: false,
      ),
      '',
    );

    // 3. Strip redundant artist prefix if title starts with "Artist - Song"
    if (artist != null && artist.trim().isNotEmpty) {
      final cleanA = cleanArtist(artist);
      final rawTrimmed = artist.trim();
      if (rawTrimmed.isNotEmpty) {
        final prefixPattern = RegExp(
          r'^\s*' + RegExp.escape(rawTrimmed) + r'\s*[-–—:]\s*',
          caseSensitive: false,
        );
        s = s.replaceAll(prefixPattern, '');
      }
      if (cleanA.isNotEmpty && cleanA.length >= 3) {
        final cleanPrefixPattern = RegExp(
          r'^\s*' + RegExp.escape(cleanA) + r'\s*[-–—:]\s*',
          caseSensitive: false,
        );
        s = s.replaceAll(cleanPrefixPattern, '');
      }
    }

    // 4. Deduplicate repeated tokens like (Acoustic) (Acoustic)
    s = deduplicateRepeatedTokens(s);

    // 5. Cleanup leftover multiple whitespace
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.isNotEmpty ? s : rawTitle.trim();
  }

  /// Normalizes a song title to its canonical core name
  static String cleanTitle(String raw) {
    if (raw.trim().isEmpty) return '';

    // 0. Normalize unicode smart/curly quotes and dashes
    var s = raw
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('‘', "'")
        .replaceAll('’', "'")
        .replaceAll('–', '-')
        .replaceAll('—', '-');

    // 1. Remove feat. / ft. suffixes
    s = s.replaceAll(_featNoise, ' ');

    // 2. Remove bracketed text: (Official Video), [4K HDR], (From "Movie"), (From 'Leo')
    s = s.replaceAll(_bracketNoise, ' ');

    // 3. Remove unbracketed movie attribution e.g. "From Movie", "- From 'Movie'"
    s = s.replaceAll(
      RegExp(r'\bfrom\s+["\x27]?[a-zA-Z0-9\s]+["\x27]?', caseSensitive: false),
      ' ',
    );

    // 4. Split by common delimiters: | : / or " - "
    final parts = s.split(RegExp(r'\s*[|:/]\s*|\s+-\s+'));
    if (parts.isNotEmpty) {
      if (parts.length >= 2) {
        final p0 = parts[0].trim();
        final p1 = parts[1].trim();
        final p1Lower = p1.toLowerCase();
        final p0Lower = p0.toLowerCase();
        // Detect "Movie - Song Video" format (e.g. "LEO - Naa Ready Song Video")
        final p1HasSongTag =
            p1Lower.contains('song') ||
            p1Lower.contains('video') ||
            p1Lower.contains('lyric') ||
            p1Lower.contains('audio') ||
            p1Lower.contains('track') ||
            p1Lower.contains('theme');
        final p0HasSongTag =
            p0Lower.contains('song') ||
            p0Lower.contains('video') ||
            p0Lower.contains('lyric') ||
            p0Lower.contains('audio') ||
            p0Lower.contains('track') ||
            p0Lower.contains('theme');
        if (p1HasSongTag && !p0HasSongTag && p1.length >= 3) {
          s = p1;
        } else if (p0.isNotEmpty) {
          s = p0;
        }
      } else if (parts.first.trim().isNotEmpty) {
        s = parts.first;
      }
    }

    // 5. Remove common video noise words
    s = s.replaceAll(_videoNoiseWords, ' ');

    // 6. Remove punctuation and collapse spaces
    s = s.replaceAll(_punctuation, ' ').replaceAll(_whitespace, ' ').trim();

    return s.toLowerCase();
  }

  /// Normalizes artist name, stripping YouTube "- Topic" and record labels/media channels
  static String cleanArtist(String raw) {
    if (raw.trim().isEmpty) return '';

    var s = raw.replaceAll(' - Topic', '').replaceAll('- Topic', '').trim();
    final lower = s.toLowerCase();

    // Check if artist is just a record label, media house, or channel
    for (final label in _labelNoise) {
      if (lower == label ||
          (lower.contains(label) && lower.length < label.length + 8) ||
          lower.startsWith('$label ') ||
          lower.endsWith(' $label')) {
        return '';
      }
    }

    // Reject channels ending with channel suffixes
    if (lower.endsWith(' media') ||
        lower.endsWith(' news') ||
        lower.endsWith(' tv') ||
        lower.endsWith(' lyrics') ||
        lower.endsWith(' studios') ||
        lower.endsWith(' pictures') ||
        lower.endsWith(' events') ||
        lower.endsWith(' channel')) {
      return '';
    }

    // Extract primary artist if comma, ampersand, or semicolon separated
    final primaryParts = s.split(RegExp(r'[,;&]'));
    if (primaryParts.isNotEmpty) {
      s = primaryParts.first;
    }

    s = s.replaceAll(_punctuation, ' ').replaceAll(_whitespace, ' ').trim();
    return s.toLowerCase();
  }

  /// Extracts primary core song title, secondary context keywords (e.g. movie/album name, composer),
  /// and resolved artist from YouTube video metadata.
  static Map<String, dynamic> extractSongContext(
    String rawTitle,
    String rawAuthor,
  ) {
    final cleanT = cleanTitle(rawTitle);
    String cleanA = cleanArtist(rawAuthor);

    final keywords = <String>[];
    // Split raw title by common delimiters: | : - – — /
    final parts = rawTitle.split(RegExp(r'\s*[|:–—/]\s*|\s+-\s+'));
    for (int i = 1; i < parts.length; i++) {
      var segment = parts[i].trim();
      segment = segment.replaceAll(_bracketNoise, ' ');
      segment = segment.replaceAll(_videoNoiseWords, ' ');
      segment = segment
          .replaceAll(_punctuation, ' ')
          .replaceAll(_whitespace, ' ')
          .trim();
      if (segment.length > 2 && !segment.toLowerCase().contains('official')) {
        keywords.add(segment);
      }
    }

    // If channel author was empty/record label, check if any keyword looks like a known artist
    if (cleanA.isEmpty && keywords.isNotEmpty) {
      for (final kw in keywords) {
        final kwLower = kw.toLowerCase();
        if (kwLower.contains('anirudh') ||
            kwLower.contains('rahman') ||
            kwLower.contains('pritam') ||
            kwLower.contains('arijit') ||
            kwLower.contains('sriram') ||
            kwLower.contains('dsp') ||
            kwLower.contains('thaman') ||
            kwLower.contains('shreya') ||
            kwLower.contains('badshah') ||
            kwLower.contains('arman') ||
            kwLower.contains('vishal')) {
          cleanA = kw;
          break;
        }
      }
    }

    return {'title': cleanT, 'artist': cleanA, 'contextKeywords': keywords};
  }

  /// Strict audio validator.
  /// Rejects YouTube videos that are speeches, press meets, trailers, dance performances,
  /// cricket highlights, teasers, wedding rituals, DJ remixes, or non-song media content.
  static bool isGenuineSong(Video video) {
    final title = video.title;
    final author = video.author;

    // 1. Blacklist non-music keywords in title
    if (_nonMusicTitleNoise.hasMatch(title)) {
      return false;
    }

    // 2. Blacklist DJ, wedding ritual, or ceremony channels
    final authorLower = author.toLowerCase().trim();
    if (authorLower.contains('varmala') ||
        authorLower.contains('vidhi') ||
        authorLower.contains('ceremony') ||
        authorLower.contains('wedding') ||
        authorLower.contains('remix hub') ||
        authorLower.startsWith('dj ') ||
        authorLower.contains(' dj ') ||
        authorLower.endsWith(' dj')) {
      return false;
    }

    // 3. Blacklist non-music channels (media, news, tv, cricket, etc.)
    if (_nonMusicAuthorNoise.hasMatch(author)) {
      final titleLower = title.toLowerCase();
      final hasSongIndicator =
          titleLower.contains('official music video') ||
          titleLower.contains('official song');
      if (!hasSongIndicator) {
        return false;
      }
    }

    // 4. Duration boundaries (authentic music tracks are 60s to 480s)
    final duration = video.duration;
    if (duration != null) {
      final sec = duration.inSeconds;
      if (sec > 0 && (sec < 60 || sec > 480)) {
        return false;
      }
    }

    return true;
  }

  static final Map<String, String> _songLanguageCache = {};

  /// Caches the confirmed language for a song (e.g. from JioSaavn or Spotify metadata)
  static void registerSongLanguage(String songId, String language) {
    if (songId.isEmpty || language.isEmpty) return;
    _songLanguageCache[songId] = language.toLowerCase().trim();
  }

  /// Retrieves cached song language
  static String? getSongLanguage(String songId) {
    if (songId.isEmpty) return null;
    return _songLanguageCache[songId];
  }

  static const Map<String, List<int>> _unicodeScripts = {
    'telugu': [0x0C00, 0x0C7F],
    'tamil': [0x0B80, 0x0BFF],
    'hindi': [0x0900, 0x097F],
    'kannada': [0x0C80, 0x0CFF],
    'malayalam': [0x0D00, 0x0D7F],
    'punjabi': [0x0A00, 0x0A7F],
    'bengali': [0x0980, 0x09FF],
    'gujarati': [0x0A80, 0x0AFF],
  };

  /// Detects native Unicode script in text
  static String? detectScript(String text, {int minCount = 4}) {
    if (text.isEmpty) return null;
    final counts = <String, int>{};
    for (final k in _unicodeScripts.keys) {
      counts[k] = 0;
    }
    for (int i = 0; i < text.length; i++) {
      final cp = text.codeUnitAt(i);
      for (final entry in _unicodeScripts.entries) {
        if (cp >= entry.value[0] && cp <= entry.value[1]) {
          counts[entry.key] = (counts[entry.key] ?? 0) + 1;
        }
      }
    }
    String? bestLang;
    int maxCount = 0;
    for (final entry in counts.entries) {
      if (entry.value > maxCount) {
        maxCount = entry.value;
        bestLang = entry.key;
      }
    }
    return maxCount >= minCount ? bestLang : null;
  }

  /// Detects language from title or metadata tags (e.g. Telugu, Hindi, Tamil, English)
  static String? detectLanguage(String text) {
    if (text.isEmpty) return null;

    // 1. Check native Unicode script first
    final script = detectScript(text, minCount: 3);
    if (script != null) return script;

    final lower = text.toLowerCase();
    if (RegExp(r'\b(telugu)\b').hasMatch(lower)) return 'telugu';
    if (RegExp(r'\b(tamil)\b').hasMatch(lower)) return 'tamil';
    if (RegExp(r'\b(hindi)\b').hasMatch(lower)) return 'hindi';
    if (RegExp(r'\b(punjabi)\b').hasMatch(lower)) return 'punjabi';
    if (RegExp(r'\b(kannada)\b').hasMatch(lower)) return 'kannada';
    if (RegExp(r'\b(malayalam)\b').hasMatch(lower)) return 'malayalam';
    if (RegExp(r'\b(bengali)\b').hasMatch(lower)) return 'bengali';
    if (RegExp(r'\b(marathi)\b').hasMatch(lower)) return 'marathi';
    if (RegExp(r'\b(gujarati)\b').hasMatch(lower)) return 'gujarati';
    if (RegExp(r'\b(bhojpuri)\b').hasMatch(lower)) return 'bhojpuri';
    if (RegExp(r'\b(english)\b').hasMatch(lower)) return 'english';

    // Channel / Record Label language associations
    if (lower.contains('aditya music') || lower.contains('madhura audio')) {
      return 'telugu';
    }
    if (lower.contains('think music')) return 'tamil';

    // Check Romanized Indic scripts
    if (LyricsTransliterationService.isRomanizedTelugu(text)) return 'telugu';
    if (LyricsTransliterationService.isRomanizedIndic(text)) return 'telugu';

    // If text contains recognized English vocabulary and is not Romanized Indic
    if (_commonEnglishWords.hasMatch(lower)) {
      return 'english';
    }

    return null;
  }

  static final RegExp _commonEnglishWords = RegExp(
    r'\b(?:the|of|and|in|to|a|is|that|for|you|it|with|on|as|are|at|be|this|have|from|or|one|had|by|word|but|not|what|all|were|we|when|your|can|said|there|use|an|each|which|she|do|how|their|if|will|up|other|about|out|many|then|them|these|so|some|her|would|make|like|him|into|time|has|look|two|more|write|go|see|number|no|way|could|people|my|than|first|water|been|call|who|oil|its|now|find|long|down|day|did|get|come|made|may|part|love|night|heart|tonight|girl|baby|never|forever|lights|star|dream|world|sun|rain|feel|away|home|life|eyes|sweet|mind|hold|dance|summer|kiss|die|fly|run|fall|again|sky|fire|magic|alone|together|perfect|shape|bad|habits|believer|blinding|closer|dynamite|senorita|stay|memories|peaches|industry|levitating|save|tears|prayer|choir|sailor|deadpool|wolverine|ed|sheeran|bruno|mars|taylor|swift|billie|eilish|coldplay|dua|lipa|justin|bieber|eminem|drake|gigi|perez|weekend|pop|rock|soundtrack|version|remix|acoustic|original|hit|hits|song|tracks|queen|beatles|adele|rihanna|shakira|post|malone|maroon|chainsmokers|imagine|dragons|alan|walker|sia|charlie|puth)\b',
    caseSensitive: false,
  );

  static final RegExp _indicArtistPattern = RegExp(
    r'\b(anirudh|devi\s+sri\s+prasad|dsp|thaman|sid\s+sriram|mangli|arijit|shreya|keeravani|'
    r'spb|balasubrahmanyam|chithra|yesudas|ram\s+miriyala|anurag\s+kulkarni|pritam|rahman|'
    r'ar\s+rahman|vishal|shekhar|badshah|honey\s+singh|diljit|jass\s+manak|sidhu\s+moose|'
    r'shankar\s+mahadevan|hariharan|karthik|armaan\s+malik|mickey\s+j\s+meyer|gopi\s+sundar|'
    r'santosh\s+narayanan|yuvan|ilaiyaraaja|harris\s+jayaraj|dhee|santhosh|sushin\s+shyam|'
    r'kasarla\s+shyam|jangi\s+reddy|penchal\s+das|bheems|vijay\s+prakash)\b',
    caseSensitive: false,
  );

  /// Identifies known Indic playback singers and composers to prevent cross-genre contamination
  static bool isKnownIndicArtist(String artist) {
    if (artist.isEmpty) return false;
    return _indicArtistPattern.hasMatch(artist.toLowerCase());
  }

  /// Evaluates whether lyrics candidate matches the expected language, artist, duration, and context
  static int scoreLyricsCandidate({
    required String? targetLang,
    required String targetTitle,
    required String targetArtist,
    int? targetDuration,
    required Map<String, dynamic> candidate,
    List<String>? contextKeywords,
    bool isTargetFeatured = false,
    String? targetFeaturedArtist,
  }) {
    final synced = candidate['syncedLyrics'] as String?;
    final plain = candidate['plainLyrics'] as String?;
    final lyrics = (synced?.isNotEmpty == true ? synced! : (plain ?? ''))
        .trim();
    if (lyrics.isEmpty) return -9999;

    // Hard reject instrumental or empty placeholders
    final lowerLyrics = lyrics.toLowerCase();
    if (lowerLyrics.contains('[instrumental]') ||
        lowerLyrics == 'instrumental' ||
        lowerLyrics.contains('lyrics not available') ||
        lowerLyrics.contains('no lyrics available')) {
      return -9999;
    }

    // Strip timestamps for script analysis
    final cleanLyrics = lyrics
        .replaceAll(RegExp(r'\[\d+:\d+\.?\d*\]'), '')
        .trim();
    if (cleanLyrics.length < 4) return -9999;

    final script = detectScript(cleanLyrics, minCount: 8);

    final trackName = (candidate['trackName'] as String? ?? '').toLowerCase();
    final albumName = (candidate['albumName'] as String? ?? '').toLowerCase();
    final cArtist = candidate['artistName'] as String? ?? '';
    final metaLang = detectLanguage('$albumName $trackName');

    final tLang = targetLang?.toLowerCase().trim();
    int score = 0;

    // 1. Strict script compatibility
    if (tLang != null && tLang.isNotEmpty) {
      if (script != null) {
        if (script != tLang) {
          // Hard reject conflicting script (e.g. Malayalam or Tamil lyrics for Telugu song)
          return -9999;
        } else {
          score += 500;
        }
      } else if (tLang == 'english' && script != null) {
        return -9999;
      }
    }

    // 2. Strict metadata language compatibility
    if (tLang != null &&
        tLang.isNotEmpty &&
        metaLang != null &&
        metaLang != 'english') {
      if (metaLang != tLang) {
        // Hard reject conflicting dubbed album tags
        return -9999;
      } else {
        score += 300;
      }
    }

    // 3. Title match
    final cTitle = cleanTitle(trackName);
    final tTitle = cleanTitle(targetTitle);
    if (cTitle == tTitle) {
      score += 250;
    } else if (cTitle.contains(tTitle) || tTitle.contains(cTitle)) {
      score += 150;
    } else {
      score -= 100;
    }

    // 4. Strict Artist match (penalize confirmed mismatch to prevent false positives)
    if (targetArtist.isNotEmpty && cArtist.isNotEmpty) {
      final tTokens = tokenize(cleanArtist(targetArtist));
      final cTokens = tokenize(cleanArtist(cArtist));
      if (tTokens.intersection(cTokens).isNotEmpty) {
        score += 180;
      } else if (tTokens.isNotEmpty) {
        score -=
            350; // Heavy penalty: prevents songs by different artists passing on generic titles
      }
    }

    // 5. Context Keywords (Movie / Album / Secondary Artists from video title)
    if (contextKeywords != null && contextKeywords.isNotEmpty) {
      final candMeta = '$trackName $albumName $cArtist'.toLowerCase();
      for (final kw in contextKeywords) {
        final cleanKw = kw.toLowerCase().trim();
        if (cleanKw.length > 2 && candMeta.contains(cleanKw)) {
          score += 150;
          break;
        }
      }
    }

    // 6. Duration match with strict boundaries
    final cDur = (candidate['duration'] as num?)?.toDouble() ?? 0.0;
    if (targetDuration != null && targetDuration > 0 && cDur > 0) {
      final diff = (cDur - targetDuration).abs();
      final ratio = diff / targetDuration;
      if (diff <= 4) {
        score += 120;
      } else if (diff <= 10) {
        score += 60;
      } else if (diff > 25 || ratio > 0.15) {
        score -= 300; // Large discrepancy
      } else if (diff > 45 || ratio > 0.25) {
        score -= 600; // Completely different song length
      }
    }

    // 7. Synced lyrics preference (massive preference for synced over plain)
    if (synced != null && synced.trim().isNotEmpty) {
      score += 300;
    }

    // 8. Feature alignment (Original vs Featured differentiation)
    final candHasFeat = isFeaturedTrack(trackName, cArtist);
    if (isTargetFeatured) {
      if (candHasFeat) {
        score += 200; // Alignment bonus for featured candidate
        if (targetFeaturedArtist != null && targetFeaturedArtist.isNotEmpty) {
          final featTokens = tokenize(targetFeaturedArtist);
          final candTokens = tokenize('$trackName $cArtist');
          if (featTokens.intersection(candTokens).isNotEmpty) {
            score += 300; // Large reward for matching target featured artist
          } else {
            score -= 200; // Mismatched guest artist
          }
        }
      } else {
        score -=
            400; // Penalize solo original candidate when resolving a featured track
      }
    } else {
      if (candHasFeat) {
        score -=
            400; // Penalize featured candidate when resolving a solo original track
      } else {
        score += 150; // Bonus for pure solo original alignment
      }
    }

    return score;
  }

  /// Verifies that candidate does not violate the seed track's language affinity.
  /// If [seedLang] is 'english', strictly blocks tracks by known Indic artists or containing Indic script.
  static bool isLanguageCompatible(
    String? seedLang,
    String candidateTitle, [
    String? candidateArtist,
  ]) {
    if (seedLang == null || seedLang.isEmpty) return true;
    final candLang = detectLanguage(candidateTitle);

    if (seedLang == 'english') {
      if (candLang != null && candLang != 'english') return false;
      if (candidateArtist != null && isKnownIndicArtist(candidateArtist)) {
        return false;
      }
      if (detectScript(candidateTitle) != null) return false;
      return true;
    }

    if (candLang == null) return true; // neutral / unlabelled
    return candLang == seedLang;
  }

  /// Extracts meaningful token set from normalized text
  static Set<String> tokenize(String text) {
    return text
        .toLowerCase()
        .split(_whitespace)
        .where((w) => w.length > 1 && !_stopwords.contains(w))
        .toSet();
  }

  /// Calculates Jaccard similarity between two token sets (0.0 to 1.0)
  static double jaccardSimilarity(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    final intersection = a.intersection(b).length;
    final union = a.union(b).length;
    if (union == 0) return 0.0;
    return intersection / union;
  }

  /// Calculates Levenshtein-based similarity (0.0 to 1.0)
  static double stringSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;

    final len1 = s1.length;
    final len2 = s2.length;
    final maxLen = max(len1, len2);
    if (maxLen == 0) return 1.0;

    // Fast-path length discrepancy
    if ((len1 - len2).abs() > (maxLen * 0.6)) return 0.0;

    final dist = _levenshteinDistance(s1, s2);
    return 1.0 - (dist / maxLen);
  }

  static int _levenshteinDistance(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    List<int> v0 = List<int>.generate(t.length + 1, (i) => i);
    List<int> v1 = List<int>.filled(t.length + 1, 0);

    for (int i = 0; i < s.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < t.length; j++) {
        final cost = (s[i] == t[j]) ? 0 : 1;
        v1[j + 1] = min(v1[j] + 1, min(v0[j + 1] + 1, v0[j] + cost));
      }
      for (int j = 0; j < t.length + 1; j++) {
        v0[j] = v1[j];
      }
    }
    return v0[t.length];
  }

  /// Extracts tokens from the full artist credit string, removing record label noise.
  static Set<String> _extractFullArtistTokens(String raw) {
    if (raw.isEmpty) return {};
    var s = raw
        .replaceAll(' - Topic', '')
        .replaceAll('- Topic', '')
        .toLowerCase();
    for (final label in _labelNoise) {
      s = s.replaceAll(label, ' ');
    }
    s = s.replaceAll(_punctuation, ' ').replaceAll(_whitespace, ' ').trim();
    return tokenize(s);
  }

  /// Determines if two song items represent the exact same track.
  static bool areDuplicateSongs({
    required String titleA,
    required String artistA,
    required String titleB,
    required String artistB,
    double threshold = 0.75,
  }) {
    final cleanTA = cleanTitle(titleA);
    final cleanTB = cleanTitle(titleB);

    if (cleanTA.isEmpty || cleanTB.isEmpty) return false;

    // Exact clean title match
    if (cleanTA == cleanTB) {
      final cleanAA = cleanArtist(artistA);
      final cleanAB = cleanArtist(artistB);
      if (cleanAA.isEmpty || cleanAB.isEmpty) return true;
      if (cleanAA == cleanAB ||
          cleanAA.contains(cleanAB) ||
          cleanAB.contains(cleanAA)) {
        return true;
      }
      final tokensAA = tokenize(cleanAA);
      final tokensAB = tokenize(cleanAB);
      if (tokensAA.intersection(tokensAB).isNotEmpty) return true;

      // Compare across all individual artists in composite credits (e.g. composer vs singer)
      final fullTokensA = _extractFullArtistTokens(artistA);
      final fullTokensB = _extractFullArtistTokens(artistB);
      if (fullTokensA.intersection(fullTokensB).isNotEmpty) return true;

      // Fuzzy match artist tokens (e.g. 'heizenberg' vs 'heisenberg', 'anirudh' vs 'anirudh ravichander')
      for (final ta in fullTokensA) {
        for (final tb in fullTokensB) {
          if (stringSimilarity(ta, tb) >= 0.80) return true;
        }
      }

      // In Indian cinema, one credit may list composer and the other playback singer
      final langA = detectLanguage(artistA);
      final langB = detectLanguage(artistB);
      final isIndicA =
          (langA != null && langA != 'english') ||
          isKnownIndicArtist(artistA) ||
          LyricsTransliterationService.isRomanizedTelugu(artistA);
      final isIndicB =
          (langB != null && langB != 'english') ||
          isKnownIndicArtist(artistB) ||
          LyricsTransliterationService.isRomanizedTelugu(artistB);
      if (isIndicA && isIndicB) {
        return true;
      }
      return false;
    }

    // Check if one title has 'Movie - Song' or 'Song (From Movie)' format matching the other
    final ctxA = extractSongContext(titleA, artistA);
    final ctxB = extractSongContext(titleB, artistB);
    final kwA = (ctxA['contextKeywords'] as List<String>?) ?? [];
    final kwB = (ctxB['contextKeywords'] as List<String>?) ?? [];

    for (final k in kwA) {
      if (cleanTitle(k) == cleanTB && cleanTB.length >= 4) return true;
    }
    for (final k in kwB) {
      if (cleanTitle(k) == cleanTA && cleanTA.length >= 4) return true;
    }

    // Token-set Jaccard overlap
    final tokensA = tokenize(cleanTA);
    final tokensB = tokenize(cleanTB);

    if (tokensA.isNotEmpty && tokensB.isNotEmpty) {
      final jaccard = jaccardSimilarity(tokensA, tokensB);
      if (jaccard >= 0.70) return true;

      // Check if one token set is a complete subset of the other (e.g. 'Kesariya' in 'Kesariya Dance')
      final intersection = tokensA.intersection(tokensB).length;
      final smallerLen = min(tokensA.length, tokensB.length);
      if (smallerLen > 0 && intersection == smallerLen && smallerLen >= 2) {
        return true;
      }
    }

    // Levenshtein string similarity on clean title
    final titleSim = stringSimilarity(cleanTA, cleanTB);
    if (titleSim >= threshold) return true;

    // Check artist consistency if title similarity is moderately high (>= 0.60)
    if (titleSim >= 0.60) {
      final cleanAA = cleanArtist(artistA);
      final cleanAB = cleanArtist(artistB);
      if (cleanAA.isNotEmpty && cleanAB.isNotEmpty) {
        if (cleanAA == cleanAB ||
            cleanAA.contains(cleanAB) ||
            cleanAB.contains(cleanAA)) {
          return true;
        }
        final tokensAA = tokenize(cleanAA);
        final tokensAB = tokenize(cleanAB);
        if (tokensAA.intersection(tokensAB).isNotEmpty) return true;
      }
    }

    return false;
  }

  /// Deduplicates [incoming] songs against [primary] existing songs.
  /// If [incoming] is omitted, deduplicates [primary] against itself.
  /// Any song in [incoming] that duplicates a song in [primary] (or earlier in [incoming]) is dropped.
  static List<Video> deduplicateList(
    List<Video> primary, [
    List<Video>? incoming,
  ]) {
    if (incoming == null) {
      final result = <Video>[];
      for (final song in primary) {
        bool isDup = false;
        for (final existing in result) {
          if (existing.id.value == song.id.value ||
              areDuplicateSongs(
                titleA: existing.title,
                artistA: existing.author,
                titleB: song.title,
                artistB: song.author,
              )) {
            isDup = true;
            break;
          }
        }
        if (!isDup) {
          result.add(song);
        }
      }
      return result;
    }

    final result = <Video>[];
    final allKnown = <Video>[...primary];

    for (final song in incoming) {
      bool isDup = false;
      for (final existing in allKnown) {
        if (existing.id.value == song.id.value ||
            areDuplicateSongs(
              titleA: existing.title,
              artistA: existing.author,
              titleB: song.title,
              artistB: song.author,
            )) {
          isDup = true;
          break;
        }
      }

      if (!isDup) {
        result.add(song);
        allKnown.add(song);
      }
    }

    return result;
  }

  /// Spaces a queue of songs so that no two consecutive songs are by the exact same
  /// artist, while preserving the recommendation ranking order (preventing oddball tracks
  /// from being arbitrarily promoted to the top of the queue).
  static List<Video> balanceArtistDistribution(List<Video> songs) {
    if (songs.length <= 2) return songs;

    final result = <Video>[];
    final remaining = List<Video>.from(songs);

    while (remaining.isNotEmpty) {
      final lastArtist = result.isEmpty
          ? null
          : cleanArtist(result.last.author);

      // Select the highest-ranked song in remaining that does not duplicate the last song's artist
      int targetIdx = 0;
      if (lastArtist != null && lastArtist.isNotEmpty) {
        final altIdx = remaining.indexWhere((s) {
          final a = cleanArtist(s.author);
          return a.isEmpty || a != lastArtist;
        });
        if (altIdx != -1) {
          targetIdx = altIdx;
        }
      }

      result.add(remaining.removeAt(targetIdx));
    }

    return result;
  }

  /// Validates whether an ID string is a genuine 11-character YouTube video ID.
  /// Purely numeric 11-character IDs or non-11 char IDs are synthetic IDs (e.g. from JioSaavn catalogs).
  static bool isLikelyYouTubeId(String id) {
    if (id.length != 11) return false;
    if (RegExp(r'^\d{11}$').hasMatch(id)) return false;
    return RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id);
  }
}
