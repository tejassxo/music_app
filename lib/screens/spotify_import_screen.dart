import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:app_links/app_links.dart';
import 'package:http/http.dart' as http;
import '../services/music_service.dart';
import '../services/api_config.dart';
import '../services/spotify_import_service.dart';
import '../services/app_file_picker.dart';
import '../widgets/dilse_scrollbar.dart';

class SpotifyImportScreen extends StatefulWidget {
  const SpotifyImportScreen({super.key});

  @override
  State<SpotifyImportScreen> createState() => _SpotifyImportScreenState();
}

class _SpotifyImportScreenState extends State<SpotifyImportScreen> {
  static const Color spotifyGreen = Color(0xFF1DB954);
  final _appLinks = AppLinks();
  final _scrollController = ScrollController();
  final _urlController = TextEditingController();
  final _csvController = TextEditingController();
  final _playlistNameController = TextEditingController();

  int _selectedTabIndex = 0; // 0 = Exportify CSV / ZIP, 1 = Spotify URL

  String? _accessToken;
  bool _isLoading = false;
  String _statusMessage = '';

  // Exportify CSV & ZIP state
  List<ExportifyTrack> _parsedExportifyTracks = [];
  List<ExportifyPlaylist> _parsedExportifyPlaylists = [];
  String? _pickedFileName;
  bool _calibrateTasteMatrix = true;

  List<dynamic> _userPlaylists = [];
  bool _showAdvancedOAuth = false;

  @override
  void initState() {
    super.initState();
    _initDeepLinkListener();
    SpotifyImportService().addListener(_onImportServiceChanged);
  }

  @override
  void dispose() {
    SpotifyImportService().removeListener(_onImportServiceChanged);
    _scrollController.dispose();
    _urlController.dispose();
    _csvController.dispose();
    _playlistNameController.dispose();
    super.dispose();
  }

  void _onImportServiceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _initDeepLinkListener() {
    _appLinks.uriLinkStream.listen((uri) {
      if (uri.scheme == 'dilsemusic' && uri.host == 'spotify-auth') {
        final token = uri.queryParameters['token'];
        final error = uri.queryParameters['error'];

        if (token != null) {
          setState(() {
            _accessToken = token;
            _statusMessage = 'Authenticated! Fetching playlists...';
          });
          _fetchUserPlaylists();
        } else if (error != null) {
          setState(() {
            _statusMessage = 'Authentication failed: $error';
          });
        }
      }
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      setState(() {
        _urlController.text = data.text!.trim();
      });
      HapticFeedback.selectionClick();
    }
  }

  Future<void> _pasteCsvFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      setState(() {
        _pickedFileName = null;
        _parsedExportifyPlaylists = [];
      });
      _handleCsvContent(
        data.text!.trim(),
        defaultName: 'Imported Spotify Liked',
      );
      HapticFeedback.selectionClick();
    }
  }

  Future<void> _pickFileFromDevice() async {
    try {
      final picked = await pickMusicArchiveOrCsv();

      if (picked != null) {
        final name = picked.name;
        final isZip = name.toLowerCase().endsWith('.zip');
        final bytes = picked.bytes;

        if (bytes.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Selected file is empty.'),
              backgroundColor: Colors.redAccent,
            ),
          );
          return;
        }

        if (isZip) {
          final playlists = ExportifyCsvParser.parseZipBytes(bytes);
          if (playlists.isEmpty) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'No CSV playlists found inside the .zip archive.',
                ),
                backgroundColor: Colors.redAccent,
              ),
            );
            return;
          }
          setState(() {
            _pickedFileName = name;
            _parsedExportifyPlaylists = playlists;
            _parsedExportifyTracks = [];
            _csvController.clear();
          });
          HapticFeedback.selectionClick();
        } else {
          final content = utf8.decode(bytes, allowMalformed: true);
          final cleanName = name.replaceAll(
            RegExp(r'\.csv$', caseSensitive: false),
            '',
          );
          setState(() {
            _pickedFileName = name;
            _parsedExportifyPlaylists = [];
          });
          _handleCsvContent(content, defaultName: cleanName);
          HapticFeedback.selectionClick();
        }
      }
    } catch (e) {
      debugPrint('[SpotifyImport] File pick error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening file: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _handleCsvContent(String content, {String? defaultName}) {
    final tracks = ExportifyCsvParser.parse(content);
    setState(() {
      _csvController.text = content;
      _parsedExportifyTracks = tracks;
      _parsedExportifyPlaylists = [];
      if (defaultName != null && _playlistNameController.text.trim().isEmpty) {
        _playlistNameController.text = defaultName;
      } else if (_playlistNameController.text.trim().isEmpty) {
        _playlistNameController.text = 'Exportify Mix';
      }
    });
  }

  void _clearPickedFiles() {
    setState(() {
      _pickedFileName = null;
      _parsedExportifyPlaylists = [];
      _parsedExportifyTracks = [];
      _csvController.clear();
      _playlistNameController.clear();
    });
  }

  String _extractPlaylistId(String input) {
    final clean = input.trim();
    final regex = RegExp(r'(?:playlist[/:])?([a-zA-Z0-9]{22})');
    final match = regex.firstMatch(clean);
    if (match != null && match.groupCount >= 1) {
      return match.group(1)!;
    }
    return clean;
  }

  Future<void> _importFromInputUrl() async {
    final rawText = _urlController.text.trim();
    if (rawText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please paste a Spotify playlist link first.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final playlistId = _extractPlaylistId(rawText);
    await _startImport(
      playlistId: playlistId,
      playlistName: 'Spotify Playlist',
      isPublic: true,
    );
  }

  Future<Map<String, dynamic>?> _tryDirectPublicImport(
    String playlistId,
  ) async {
    if (kIsWeb) return null;

    try {
      final embedUrl = Uri.parse(
        'https://open.spotify.com/embed/playlist/$playlistId',
      );
      final res = await http
          .get(
            embedUrl,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final html = res.body;
        final match = RegExp(
          r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
        ).firstMatch(html);
        if (match != null && match.groupCount >= 1) {
          final data = json.decode(match.group(1)!);
          final entity =
              data['props']?['pageProps']?['state']?['data']?['entity'];
          if (entity != null) {
            final name = entity['name'] as String? ?? 'Spotify Playlist';
            final rawList = List<dynamic>.from(entity['trackList'] ?? []);
            final List<String> tracks = [];
            for (final item in rawList) {
              if (item is Map) {
                final title = (item['title'] as String? ?? '').trim();
                final subtitle = (item['subtitle'] as String? ?? '')
                    .replaceAll('\u00a0', ' ')
                    .trim();
                if (title.isNotEmpty) {
                  tracks.add('$title $subtitle'.trim());
                }
              }
            }
            if (tracks.isNotEmpty) {
              return {'name': name, 'tracks': tracks, 'total': tracks.length};
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[SpotifyImport] Direct embed scrape fallback error: $e');
    }
    return null;
  }

  Future<void> _startImport({
    required String playlistId,
    required String playlistName,
    required bool isPublic,
  }) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _statusMessage = 'Extracting tracks from Spotify playlist...';
    });

    try {
      Map<String, dynamic>? data;

      // 1. Direct on-device scrape for mobile/desktop (instant, zero-server)
      if (isPublic && !kIsWeb) {
        data = await _tryDirectPublicImport(playlistId);
      }

      // 2. Fetch from backend API
      if (data == null) {
        final res = await http
            .post(
              Uri.parse('${ApiConfig.baseUrl}/spotify/import'),
              headers: {'Content-Type': 'application/json'},
              body: json.encode({
                'access_token': _accessToken,
                'playlist_id': playlistId,
                'is_public': isPublic,
              }),
            )
            .timeout(const Duration(seconds: 30));

        if (res.statusCode == 200) {
          data = json.decode(res.body);
        } else {
          final err = json.decode(res.body);
          final detail = err['detail'] as String? ?? 'Could not fetch playlist';
          setState(() {
            _statusMessage = 'Import error: $detail';
          });
          return;
        }
      }

      if (data == null) {
        setState(() {
          _statusMessage = 'Could not fetch playlist data. Please try again.';
        });
        return;
      }

      final tracks = List<String>.from(data['tracks'] ?? []);
      final fetchedName = (data['name'] as String?) ?? playlistName;

      if (tracks.isEmpty) {
        setState(() {
          _statusMessage =
              'No tracks found. Please make sure the playlist is Public.';
        });
        return;
      }

      // Dispatch to decoupled persistent background engine
      SpotifyImportService().startBackgroundUrlImport(
        playlistId: playlistId,
        playlistName: fetchedName,
        rawTrackQueries: tracks,
      );
    } catch (e) {
      setState(() {
        _statusMessage = 'Error during import: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _startExportifyCsvImport() async {
    if (_parsedExportifyTracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No tracks found to import. Please upload or paste a valid CSV.',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    final playlistTitle = _playlistNameController.text.trim().isNotEmpty
        ? _playlistNameController.text.trim()
        : 'Exportify Mix';

    // Dispatch to decoupled persistent background engine with 8 parallel workers
    SpotifyImportService().startBackgroundSingleImport(
      playlistName: playlistTitle,
      tracks: _parsedExportifyTracks,
      calibrateTaste: _calibrateTasteMatrix,
    );
  }

  Future<void> _startMultiPlaylistImport() async {
    final selected = _parsedExportifyPlaylists
        .where((p) => p.isSelected && p.tracks.isNotEmpty)
        .toList();
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select at least one playlist to import.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    // Dispatch all playlists to background multi-import with cross-playlist caching & concurrency
    SpotifyImportService().startBackgroundMultiImport(
      playlists: selected,
      calibrateTaste: _calibrateTasteMatrix,
    );
  }

  // --- Optional / Advanced OAuth Flows ---

  Future<void> _loginWithSpotify() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Opening Spotify login...';
    });

    try {
      final res = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/spotify/login'),
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final url = Uri.parse(data['url']);
        if (await canLaunchUrl(url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        } else {
          setState(() => _statusMessage = 'Could not launch browser.');
        }
      } else {
        setState(
          () => _statusMessage =
              'Server requires Spotify developer keys for login.',
        );
      }
    } catch (e) {
      setState(() => _statusMessage = 'Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchUserPlaylists() async {
    if (_accessToken == null) return;
    setState(() => _isLoading = true);

    try {
      final res = await http.get(
        Uri.parse(
          '${ApiConfig.baseUrl}/spotify/playlists?access_token=$_accessToken',
        ),
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        setState(() {
          _userPlaylists = data['playlists'] ?? [];
          _statusMessage =
              'Found ${_userPlaylists.length} playlists in your account.';
        });
      } else {
        setState(() => _statusMessage = 'Failed to fetch playlists.');
      }
    } catch (e) {
      setState(() => _statusMessage = 'Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final importService = SpotifyImportService();
    final isBackgroundActive = importService.isImporting;
    final hasBackgroundFinished = importService.hasFinished;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && isBackgroundActive) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Import continuing in background. Feel free to browse or play music!',
              ),
              backgroundColor: spotifyGreen,
              duration: Duration(seconds: 3),
            ),
          );
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0B0F),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0B0B0F),
          elevation: 0,
          title: const Text(
            'Import & Calibrate Taste',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontSize: 18,
            ),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: DilSeScrollbar(
          controller: _scrollController,
          bottomPadding: 30.0,
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(
              horizontal: 20.0,
              vertical: 16.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (isBackgroundActive) ...[
                  _buildBackgroundActiveDashboard(importService),
                ] else if (hasBackgroundFinished) ...[
                  _buildBackgroundFinishedDashboard(importService),
                ] else ...[
                  _buildModeSelector(),
                  const SizedBox(height: 20),
                  if (_selectedTabIndex == 0) ...[
                    _buildExportifyHeader(),
                    const SizedBox(height: 20),
                    _buildExportifyInputs(),
                  ] else ...[
                    _buildUrlHeader(),
                    const SizedBox(height: 20),
                    _buildUrlInputs(),
                  ],
                  if (_statusMessage.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _buildStaticStatusCard(),
                  ],
                ],
                const SizedBox(height: 24),

                // Optional Advanced OAuth Accordion
                Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    initiallyExpanded: _showAdvancedOAuth,
                    onExpansionChanged: (val) =>
                        setState(() => _showAdvancedOAuth = val),
                    title: Text(
                      'Developer Options (Spotify Account Login)',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12.0),
                        child: Text(
                          'Requires Spotify Developer Client credentials configured on your backend server.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      if (_accessToken == null)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.login_rounded, size: 18),
                          label: const Text('Log In With Spotify Account'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: spotifyGreen,
                            side: BorderSide(
                              color: spotifyGreen.withValues(alpha: 0.4),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: _isLoading ? null : _loginWithSpotify,
                        )
                      else ...[
                        Text(
                          'Your Spotify Playlists (${_userPlaylists.length})',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _userPlaylists.length,
                          itemBuilder: (context, index) {
                            final pl = _userPlaylists[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                pl['name'] ?? 'Unknown',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                '${pl['total_tracks']} tracks',
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.download_rounded,
                                  color: spotifyGreen,
                                ),
                                onPressed: _isLoading
                                    ? null
                                    : () => _startImport(
                                        playlistId: pl['id'] ?? '',
                                        playlistName: pl['name'] ?? 'Playlist',
                                        isPublic: false,
                                      ),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF181824),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: _isLoading
                  ? null
                  : () => setState(() => _selectedTabIndex = 0),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _selectedTabIndex == 0
                      ? spotifyGreen
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.file_present_rounded,
                      size: 18,
                      color: _selectedTabIndex == 0
                          ? Colors.black
                          : Colors.white70,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Exportify CSV',
                      style: TextStyle(
                        color: _selectedTabIndex == 0
                            ? Colors.black
                            : Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: _isLoading
                  ? null
                  : () => setState(() => _selectedTabIndex = 1),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _selectedTabIndex == 1
                      ? spotifyGreen
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.link_rounded,
                      size: 18,
                      color: _selectedTabIndex == 1
                          ? Colors.black
                          : Colors.white70,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Spotify URL',
                      style: TextStyle(
                        color: _selectedTabIndex == 1
                            ? Colors.black
                            : Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundActiveDashboard(SpotifyImportService service) {
    final pct = (service.overallProgress * 100).toInt();
    final isMulti = service.totalPlaylists > 1;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF14141E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: spotifyGreen.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: spotifyGreen.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: spotifyGreen.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: spotifyGreen,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'IMPORTING IN BACKGROUND',
                      style: TextStyle(
                        color: spotifyGreen,
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                '$pct%',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: service.overallProgress > 0
                  ? service.overallProgress
                  : null,
              backgroundColor: Colors.white10,
              color: spotifyGreen,
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            service.statusMessage,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                if (isMulti) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Playlists Progress',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                      Text(
                        '${service.completedPlaylists} of ${service.totalPlaylists} playlists',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Studio Tracks Resolved',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    Text(
                      '${service.resolvedTracks} of ${service.totalTracks} songs',
                      style: const TextStyle(
                        color: spotifyGreen,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                if (service.cacheHitCount > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '⚡ Cross-Playlist Deduplication',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                      Text(
                        '${service.cacheHitCount} cached (0ms)',
                        style: const TextStyle(
                          color: Colors.cyanAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text(
              'Run in Background & Browse Music',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E1E2C),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
            ),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Import continuing in background. Feel free to browse or play music!',
                  ),
                  backgroundColor: spotifyGreen,
                  duration: Duration(seconds: 3),
                ),
              );
              Navigator.pop(context);
            },
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            icon: const Icon(
              Icons.cancel_outlined,
              size: 16,
              color: Colors.redAccent,
            ),
            label: const Text(
              'Cancel Import',
              style: TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
            onPressed: () {
              service.cancelImport();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundFinishedDashboard(SpotifyImportService service) {
    final wasCancelled = service.isCancelled;
    final accentColor = wasCancelled ? const Color(0xFFFFA726) : spotifyGreen;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF14141E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accentColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              wasCancelled
                  ? Icons.pause_circle_outline_rounded
                  : Icons.check_rounded,
              color: accentColor,
              size: 32,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            wasCancelled ? 'Import Stopped' : 'Import Completed!',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            service.statusMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () {
                    service.resetFinishedState();
                    Navigator.pop(context);
                  },
                  child: const Text('Go to Library'),
                ),
              ),
              if (service.lastImportedPlaylistId != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: const Text('Play Now'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: spotifyGreen,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () {
                      final pid = service.lastImportedPlaylistId!;
                      service.resetFinishedState();
                      MusicService().playCustomPlaylist(pid, 0);
                      Navigator.pop(context);
                    },
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => service.resetFinishedState(),
            child: const Text(
              'Import Another File or Playlist',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStaticStatusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF14141E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        _statusMessage,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          height: 1.4,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildExportifyHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            spotifyGreen.withValues(alpha: 0.15),
            const Color(0xFF14141E),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: spotifyGreen.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: spotifyGreen.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.insights_rounded,
                  color: spotifyGreen,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Exportify Taste Ingestion',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Zero-auth import for single playlists (.csv) or full backups (.zip) with audio features.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  color: Colors.white54,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Export any playlist or click "Export All" (.zip) on exportify.net, then upload or paste here.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExportifyInputs() {
    if (_parsedExportifyPlaylists.isNotEmpty) {
      return _buildMultiPlaylistView();
    }

    final hasTracks = _parsedExportifyTracks.isNotEmpty;

    // Calculate audio stats
    double avgEnergy = 0;
    double avgValence = 0;
    double avgDance = 0;
    double avgTempo = 0;
    int count = 0;
    final artistCounts = <String, int>{};

    if (hasTracks) {
      for (final t in _parsedExportifyTracks) {
        if (t.energy > 0 || t.valence > 0) {
          avgEnergy += t.energy;
          avgValence += t.valence;
          avgDance += t.danceability;
          avgTempo += t.tempo;
          count++;
        }
        final mainArtist = t.artistName.split(',').first.trim();
        if (mainArtist.isNotEmpty) {
          artistCounts[mainArtist] = (artistCounts[mainArtist] ?? 0) + 1;
        }
      }
      if (count > 0) {
        avgEnergy /= count;
        avgValence /= count;
        avgDance /= count;
        avgTempo /= count;
      }
    }

    final topArtists = artistCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Upload Button & Paste Button Row
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text(
                  'Browse .CSV or .ZIP',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E1E2C),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                ),
                onPressed: _isLoading ? null : _pickFileFromDevice,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text(
                  'Paste CSV Text',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: spotifyGreen.withValues(alpha: 0.15),
                  foregroundColor: spotifyGreen,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                  side: BorderSide(color: spotifyGreen.withValues(alpha: 0.3)),
                ),
                onPressed: _isLoading ? null : _pasteCsvFromClipboard,
              ),
            ),
          ],
        ),

        if (_pickedFileName != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF181824),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.insert_drive_file_rounded,
                  color: spotifyGreen,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _pickedFileName!,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Colors.white54,
                  ),
                  onPressed: _isLoading ? null : _clearPickedFiles,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 16),

        // CSV Text Preview Field
        Container(
          height: 120,
          decoration: BoxDecoration(
            color: const Color(0xFF181824),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: TextField(
            controller: _csvController,
            maxLines: null,
            expands: true,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
            enabled: !_isLoading,
            decoration: InputDecoration(
              hintText:
                  'Paste Exportify CSV content here...\n(Track Name, Artist Name, Energy, Valence...)',
              hintStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 12,
              ),
              contentPadding: const EdgeInsets.all(14),
              border: InputBorder.none,
            ),
            onChanged: (text) => _handleCsvContent(text),
          ),
        ),

        // Live Audio Features & Taste Stats Card
        if (hasTracks) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF14141E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: spotifyGreen.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Detected: ${_parsedExportifyTracks.length} Tracks',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: spotifyGreen.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'CALIBRATION READY',
                        style: TextStyle(
                          color: spotifyGreen,
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Audio features chips
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildFeatureChip(
                      '⚡ Energy',
                      '${(avgEnergy * 100).toInt()}%',
                      Colors.amber,
                    ),
                    _buildFeatureChip(
                      '💃 Dance',
                      '${(avgDance * 100).toInt()}%',
                      Colors.cyanAccent,
                    ),
                    _buildFeatureChip(
                      '💖 Vibe',
                      '${(avgValence * 100).toInt()}%',
                      Colors.pinkAccent,
                    ),
                    _buildFeatureChip(
                      '⏱️ BPM',
                      '${avgTempo.toInt()}',
                      Colors.greenAccent,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Top Artists preview
                if (topArtists.isNotEmpty) ...[
                  Text(
                    'Top Artists: ${topArtists.take(4).map((e) => e.key).join(", ")}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Playlist Name Field
          TextField(
            controller: _playlistNameController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Playlist Name in DilSe',
              labelStyle: const TextStyle(color: Colors.white70, fontSize: 13),
              filled: true,
              fillColor: const Color(0xFF181824),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Taste Matrix calibration switch
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _calibrateTasteMatrix,
            activeThumbColor: spotifyGreen,
            title: const Text(
              'Calibrate Taste Matrix & Circadian Engine',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              'Immediately tunes your Daily Mixes and Circadian vibe with these audio features.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
            onChanged: (val) => setState(() => _calibrateTasteMatrix = val),
          ),
        ],

        const SizedBox(height: 16),

        // Action Button
        SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.black,
                    ),
                  )
                : const Icon(Icons.offline_bolt_rounded, size: 22),
            label: Text(
              _isLoading
                  ? 'Importing & Resolving Studio Audio...'
                  : (hasTracks
                        ? 'Import ${_parsedExportifyTracks.length} Tracks to DilSe'
                        : 'Load CSV to Import'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: hasTracks ? spotifyGreen : Colors.white12,
              foregroundColor: hasTracks ? Colors.black : Colors.white38,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: (_isLoading || !hasTracks)
                ? null
                : _startExportifyCsvImport,
          ),
        ),
      ],
    );
  }

  Widget _buildMultiPlaylistView() {
    final selectedPlaylists = _parsedExportifyPlaylists
        .where((p) => p.isSelected)
        .toList();
    final allSelectedTracks = selectedPlaylists
        .expand((p) => p.tracks)
        .toList();
    final totalTracks = _parsedExportifyPlaylists.fold<int>(
      0,
      (sum, p) => sum + p.tracks.length,
    );

    // Compute aggregate audio stats across selected
    double avgEnergy = 0;
    double avgValence = 0;
    double avgDance = 0;
    double avgTempo = 0;
    int featureCount = 0;

    for (final t in allSelectedTracks) {
      if (t.energy > 0 || t.valence > 0) {
        avgEnergy += t.energy;
        avgValence += t.valence;
        avgDance += t.danceability;
        avgTempo += t.tempo;
        featureCount++;
      }
    }
    if (featureCount > 0) {
      avgEnergy /= featureCount;
      avgValence /= featureCount;
      avgDance /= featureCount;
      avgTempo /= featureCount;
    }

    final allSelected =
        _parsedExportifyPlaylists.isNotEmpty &&
        _parsedExportifyPlaylists.every((p) => p.isSelected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Archive Header Card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF14141E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: spotifyGreen.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: spotifyGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.folder_zip_rounded,
                      color: spotifyGreen,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _pickedFileName ?? 'Exportify Archive.zip',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_parsedExportifyPlaylists.length} Playlists • $totalTracks Total Songs Found',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white54,
                      size: 20,
                    ),
                    tooltip: 'Remove Archive',
                    onPressed: _isLoading ? null : _clearPickedFiles,
                  ),
                ],
              ),
              if (featureCount > 0) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildFeatureChip(
                      '⚡ Energy',
                      '${(avgEnergy * 100).toInt()}%',
                      Colors.amber,
                    ),
                    _buildFeatureChip(
                      '💃 Dance',
                      '${(avgDance * 100).toInt()}%',
                      Colors.cyanAccent,
                    ),
                    _buildFeatureChip(
                      '💖 Vibe',
                      '${(avgValence * 100).toInt()}%',
                      Colors.pinkAccent,
                    ),
                    _buildFeatureChip(
                      '⏱️ BPM',
                      '${avgTempo.toInt()}',
                      Colors.greenAccent,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Selection Controls Row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${selectedPlaylists.length} of ${_parsedExportifyPlaylists.length} selected (${allSelectedTracks.length} tracks)',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: spotifyGreen,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              icon: Icon(
                allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
                size: 16,
              ),
              label: Text(
                allSelected ? 'Deselect All' : 'Select All',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onPressed: _isLoading
                  ? null
                  : () {
                      setState(() {
                        final target = !allSelected;
                        for (final p in _parsedExportifyPlaylists) {
                          p.isSelected = target;
                        }
                      });
                      HapticFeedback.selectionClick();
                    },
            ),
          ],
        ),

        const SizedBox(height: 8),

        // Playlist Cards List
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _parsedExportifyPlaylists.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final pl = _parsedExportifyPlaylists[index];
            return Container(
              decoration: BoxDecoration(
                color: pl.isSelected
                    ? const Color(0xFF181824)
                    : const Color(0xFF12121A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: pl.isSelected
                      ? spotifyGreen.withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.05),
                ),
              ),
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: ValueKey('${pl.name}_$index'),
                  leading: Checkbox(
                    value: pl.isSelected,
                    activeColor: spotifyGreen,
                    checkColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    onChanged: _isLoading
                        ? null
                        : (val) {
                            setState(() {
                              pl.isSelected = val ?? false;
                            });
                          },
                  ),
                  title: Text(
                    pl.name,
                    style: TextStyle(
                      color: pl.isSelected ? Colors.white : Colors.white60,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: Row(
                    children: [
                      Text(
                        '${pl.tracks.length} tracks',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '•',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.3),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '⚡ ${(pl.avgEnergy * 100).toInt()}% • 💖 ${(pl.avgValence * 100).toInt()}%',
                        style: TextStyle(
                          color: spotifyGreen.withValues(alpha: 0.8),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Preview tracks:',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 4),
                          ...pl.tracks
                              .take(4)
                              .map(
                                (t) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2.0,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.music_note_rounded,
                                        size: 12,
                                        color: spotifyGreen,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          '${t.trackName} - ${t.artistName}',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          if (pl.tracks.length > 4)
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text(
                                '+ ${pl.tracks.length - 4} more tracks',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),

        const SizedBox(height: 16),

        // Taste Matrix Switch
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _calibrateTasteMatrix,
          activeThumbColor: spotifyGreen,
          title: const Text(
            'Calibrate Taste Matrix & Circadian Engine',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            'Combines audio features across all selected playlists to hyper-tune your recommendations.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11,
            ),
          ),
          onChanged: (val) => setState(() => _calibrateTasteMatrix = val),
        ),

        const SizedBox(height: 16),

        // Import Button
        SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.black,
                    ),
                  )
                : const Icon(Icons.library_add_check_rounded, size: 22),
            label: Text(
              _isLoading
                  ? 'Importing ${selectedPlaylists.length} Playlists...'
                  : (selectedPlaylists.isNotEmpty
                        ? 'Import ${selectedPlaylists.length} Playlists (${allSelectedTracks.length} Tracks)'
                        : 'Select Playlists to Import'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: selectedPlaylists.isNotEmpty
                  ? spotifyGreen
                  : Colors.white12,
              foregroundColor: selectedPlaylists.isNotEmpty
                  ? Colors.black
                  : Colors.white38,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: (_isLoading || selectedPlaylists.isEmpty)
                ? null
                : _startMultiPlaylistImport,
          ),
        ),

        const SizedBox(height: 10),

        OutlinedButton.icon(
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text(
            'Pick Another File or Paste CSV',
            style: TextStyle(fontSize: 12),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white70,
            side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _isLoading ? null : _clearPickedFiles,
        ),
      ],
    );
  }

  Widget _buildFeatureChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _buildUrlHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            spotifyGreen.withValues(alpha: 0.15),
            const Color(0xFF14141E),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: spotifyGreen.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: spotifyGreen.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.playlist_add_check_rounded,
              color: spotifyGreen,
              size: 34,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Instant Spotify URL Importer',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Paste any public Spotify playlist link to save and stream studio tracks on DilSe.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUrlInputs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Spotify Playlist Link',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF181824),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: TextField(
            controller: _urlController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            enabled: !_isLoading,
            decoration: InputDecoration(
              hintText: 'https://open.spotify.com/playlist/...',
              hintStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 13,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
              border: InputBorder.none,
              prefixIcon: const Icon(
                Icons.link_rounded,
                color: spotifyGreen,
                size: 22,
              ),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_urlController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(
                        Icons.clear,
                        color: Colors.white54,
                        size: 18,
                      ),
                      onPressed: () => setState(() => _urlController.clear()),
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.content_paste_rounded,
                      color: spotifyGreen,
                      size: 20,
                    ),
                    tooltip: 'Paste from clipboard',
                    onPressed: _isLoading ? null : _pasteFromClipboard,
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.black,
                    ),
                  )
                : const Icon(Icons.download_rounded, size: 22),
            label: Text(
              _isLoading ? 'Importing Playlist...' : 'Import Playlist',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: spotifyGreen,
              foregroundColor: Colors.black,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _isLoading ? null : _importFromInputUrl,
          ),
        ),
      ],
    );
  }
}
