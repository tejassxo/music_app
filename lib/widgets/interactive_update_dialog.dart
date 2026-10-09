import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/update_service.dart';
import '../services/preferences_service.dart';

class InteractiveUpdateDialog extends StatefulWidget {
  final AppUpdateInfo info;

  const InteractiveUpdateDialog({super.key, required this.info});

  @override
  State<InteractiveUpdateDialog> createState() =>
      _InteractiveUpdateDialogState();
}

class _InteractiveUpdateDialogState extends State<InteractiveUpdateDialog>
    with SingleTickerProviderStateMixin {
  bool _isDownloading = false;
  int _downloadProgress = 0;
  String _statusText = 'Preparing download...';
  String? _errorMessage;
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutBack,
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _startOta() async {
    if (_isDownloading) return;

    if (!_isAndroid) {
      _openInBrowser();
      return;
    }

    try {
      final status = await Permission.requestInstallPackages.status;
      if (!status.isGranted) {
        final result = await Permission.requestInstallPackages.request();
        if (!result.isGranted) {
          if (!mounted) return;
          setState(() {
            _errorMessage =
                'Permission needed to install update. Enable "Install unknown apps" or download via browser.';
          });
          return;
        }
      }
    } catch (_) {
      // Continue if permission check throws
    }

    if (!mounted) return;
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _statusText = 'Downloading update...';
      _errorMessage = null;
    });

    try {
      UpdateService()
          .startOtaUpdate(widget.info.downloadUrl)
          .listen(
            (OtaEvent event) {
              if (!mounted) return;
              switch (event.status) {
                case OtaStatus.DOWNLOADING:
                  final p = int.tryParse(event.value ?? '0') ?? 0;
                  setState(() {
                    _downloadProgress = p;
                    _statusText = 'Downloading update... ($p%)';
                  });
                  break;
                case OtaStatus.INSTALLING:
                  setState(() {
                    _statusText = 'Launching package installer...';
                  });
                  break;
                case OtaStatus.ALREADY_RUNNING_ERROR:
                  setState(() {
                    _isDownloading = false;
                    _errorMessage = 'Download already in progress.';
                  });
                  break;
                case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
                  setState(() {
                    _isDownloading = false;
                    _errorMessage =
                        'Storage/Install permission was not granted.';
                  });
                  break;
                case OtaStatus.INTERNAL_ERROR:
                default:
                  setState(() {
                    _isDownloading = false;
                    _errorMessage =
                        'Download error: ${event.value ?? 'Unknown'}';
                  });
                  break;
              }
            },
            onError: (err) {
              if (!mounted) return;
              setState(() {
                _isDownloading = false;
                _errorMessage = 'Update error: $err';
              });
            },
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _errorMessage = 'Could not start OTA: $e';
      });
    }
  }

  Future<void> _openInBrowser({bool forceApk = false}) async {
    final targetUrl = (!forceApk && kIsWeb)
        ? (widget.info.releasePageUrl ?? widget.info.downloadUrl)
        : widget.info.downloadUrl;
    final uri = Uri.parse(targetUrl);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        setState(() {
          _errorMessage = 'Could not launch release URL in browser.';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Browser error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = PreferencesService().themeColor;

    return ScaleTransition(
      scale: _scaleAnimation,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: BoxDecoration(
            color: const Color(0xFF14141E),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: themeColor.withValues(alpha: 0.35),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: themeColor.withValues(alpha: 0.25),
                blurRadius: 36,
                spreadRadius: 2,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.8),
                blurRadius: 20,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Stack(
              children: [
                // Top decorative accent glow
                Positioned(
                  top: -60,
                  right: -60,
                  child: Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          themeColor.withValues(alpha: 0.4),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                // Close "X" Cross symbol button at top right
                Positioned(
                  top: 12,
                  right: 12,
                  child: Material(
                    color: Colors.white.withValues(alpha: 0.08),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.all(8.0),
                        child: Icon(
                          Icons.close_rounded,
                          color: Colors.white70,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header with glowing icon
                      Row(
                        children: [
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  themeColor,
                                  themeColor.withValues(alpha: 0.6),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: themeColor.withValues(alpha: 0.4),
                                  blurRadius: 14,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.rocket_launch_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Update Ready!',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.3,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: themeColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: themeColor.withValues(alpha: 0.3),
                                    ),
                                  ),
                                  child: Text(
                                    kIsWeb
                                        ? '${widget.info.currentVersion} ➔ ${widget.info.tagName} • Web'
                                        : '${widget.info.currentVersion} ➔ ${widget.info.tagName} • ${widget.info.formattedSize}',
                                    style: TextStyle(
                                      color: themeColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),

                      // What's new container
                      const Text(
                        "What's New in DilSe",
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 140),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0C0C14),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            widget.info.changelog.isEmpty
                                ? '• Unlocked 320kbps English & International music\n• Queue drag-and-drop reordering\n• Smooth sleep timer fade-out\n• Spotify-style curated mixes & trending charts\n• Performance & background playback improvements'
                                : widget.info.changelog,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Error message if any
                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.redAccent.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.error_outline_rounded,
                                    color: Colors.redAccent,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _errorMessage!,
                                      style: const TextStyle(
                                        color: Colors.redAccent,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              GestureDetector(
                                onTap: () => _openInBrowser(),
                                child: Text(
                                  kIsWeb
                                      ? 'Tap here to view release in browser ➔'
                                      : 'Tap here to download APK in browser ➔',
                                  style: const TextStyle(
                                    color: Colors.amberAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // Downloading progress vs Buttons
                      if (_isDownloading) ...[
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _statusText,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  '$_downloadProgress%',
                                  style: TextStyle(
                                    color: themeColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: _downloadProgress > 0
                                    ? _downloadProgress / 100.0
                                    : null,
                                minHeight: 8,
                                backgroundColor: Colors.white12,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  themeColor,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Center(
                              child: Text(
                                'Keep DilSe open while downloading',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else if (kIsWeb) ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                child: const Text(
                                  'Dismiss',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: ElevatedButton(
                                onPressed: () => _openInBrowser(),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: themeColor,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  shadowColor: themeColor.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Icon(Icons.open_in_new_rounded, size: 20),
                                    SizedBox(width: 8),
                                    Text(
                                      'View Release',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (widget.info.downloadUrl.endsWith('.apk')) ...[
                          const SizedBox(height: 10),
                          Center(
                            child: TextButton.icon(
                              onPressed: () => _openInBrowser(forceApk: true),
                              icon: const Icon(
                                Icons.android_rounded,
                                size: 16,
                                color: Colors.white54,
                              ),
                              label: Text(
                                'Download Android APK (${widget.info.formattedSize})',
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ] else ...[
                        Row(
                          children: [
                            // "Later" button
                            Expanded(
                              child: TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                child: const Text(
                                  'Later',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Download button
                            Expanded(
                              flex: 2,
                              child: ElevatedButton(
                                onPressed: _startOta,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: themeColor,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  shadowColor: themeColor.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Icon(Icons.download_rounded, size: 20),
                                    SizedBox(width: 8),
                                    Text(
                                      'Download Now',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
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
}
