import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppUpdateInfo {
  final String tagName;
  final String releaseName;
  final String changelog;
  final String downloadUrl;
  final int apkSizeBytes;
  final String currentVersion;
  final String currentBuildNumber;
  final bool hasUpdate;
  final String? releasePageUrl;

  AppUpdateInfo({
    required this.tagName,
    required this.releaseName,
    required this.changelog,
    required this.downloadUrl,
    required this.apkSizeBytes,
    required this.currentVersion,
    required this.currentBuildNumber,
    required this.hasUpdate,
    this.releasePageUrl,
  });

  String get formattedSize {
    if (apkSizeBytes <= 0) return 'Unknown size';
    final mb = apkSizeBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}

class GitHubReleaseItem {
  final String tagName;
  final String releaseName;
  final String changelog;
  final String? apkDownloadUrl;
  final String? apkFileName;
  final int apkSizeBytes;
  final DateTime? publishedAt;
  final bool isPrerelease;
  final bool isDraft;
  final String htmlUrl;

  GitHubReleaseItem({
    required this.tagName,
    required this.releaseName,
    required this.changelog,
    this.apkDownloadUrl,
    this.apkFileName,
    required this.apkSizeBytes,
    this.publishedAt,
    required this.isPrerelease,
    required this.isDraft,
    required this.htmlUrl,
  });

  String get formattedSize {
    if (apkSizeBytes <= 0) return 'Source only';
    final mb = apkSizeBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  bool get hasApk => apkDownloadUrl != null && apkDownloadUrl!.isNotEmpty;
}

class UpdateService {
  static final UpdateService _instance = UpdateService._internal();
  factory UpdateService() => _instance;
  UpdateService._internal();

  static const String _githubRepoOwner = 'charanteja-k';
  static const String _githubRepoName = 'music_app';

  /// Queries GitHub Releases for the latest release and checks if it is newer
  /// than the currently installed app version.
  Future<AppUpdateInfo?> checkForUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final currentBuildNumber = packageInfo.buildNumber;

      final url = Uri.parse(
        'https://api.github.com/repos/$_githubRepoOwner/$_githubRepoName/releases/latest',
      );
      final response = await http
          .get(
            url,
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'MusicApp-Updater',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint(
          '[UpdateService] GitHub releases returned status: ${response.statusCode}',
        );
        return null;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String? ?? '').trim();
      final releaseName = (data['name'] as String? ?? tagName).trim();
      final changelog =
          (data['body'] as String? ?? 'Bug fixes and performance improvements.')
              .trim();
      final htmlUrl = (data['html_url'] as String? ?? '').trim();
      final releasePage = htmlUrl.isNotEmpty
          ? htmlUrl
          : 'https://github.com/$_githubRepoOwner/$_githubRepoName/releases/tag/$tagName';

      // Find APK asset in release
      final assets = (data['assets'] as List<dynamic>? ?? []);
      String? apkDownloadUrl;
      int apkSize = 0;

      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.apk')) {
          apkDownloadUrl = asset['browser_download_url'] as String?;
          apkSize = (asset['size'] as num? ?? 0).toInt();
          break;
        }
      }

      if (!kIsWeb && (apkDownloadUrl == null || apkDownloadUrl.isEmpty)) {
        debugPrint(
          '[UpdateService] No APK asset found in latest GitHub release ($tagName)',
        );
        return null;
      }

      final hasUpdate = _isRemoteNewer(
        remoteTag: tagName,
        currentVersion: currentVersion,
        currentBuild: currentBuildNumber,
      );

      return AppUpdateInfo(
        tagName: tagName,
        releaseName: releaseName,
        changelog: changelog,
        downloadUrl: apkDownloadUrl ?? releasePage,
        apkSizeBytes: apkSize,
        currentVersion: currentVersion,
        currentBuildNumber: currentBuildNumber,
        hasUpdate: hasUpdate,
        releasePageUrl: releasePage,
      );
    } catch (e) {
      debugPrint('[UpdateService] Error checking for updates: $e');
      return null;
    }
  }

  /// Fetches all GitHub releases for the repository to allow installing or rolling back
  /// to any previous version.
  Future<List<GitHubReleaseItem>> fetchAllReleases({int perPage = 30}) async {
    try {
      final url = Uri.parse(
        'https://api.github.com/repos/$_githubRepoOwner/$_githubRepoName/releases?per_page=$perPage',
      );
      final response = await http
          .get(
            url,
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'MusicApp-Updater',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        debugPrint(
          '[UpdateService] fetchAllReleases returned status: ${response.statusCode}',
        );
        return [];
      }

      final List<dynamic> rawList = json.decode(response.body) as List<dynamic>;
      final releases = <GitHubReleaseItem>[];

      for (final item in rawList) {
        if (item is! Map<String, dynamic>) continue;

        final tagName = (item['tag_name'] as String? ?? '').trim();
        if (tagName.isEmpty) continue;

        final releaseName = (item['name'] as String? ?? tagName).trim();
        final changelog = (item['body'] as String? ?? '').trim();
        final isPrerelease = item['prerelease'] as bool? ?? false;
        final isDraft = item['draft'] as bool? ?? false;
        final htmlUrl = (item['html_url'] as String? ?? '').trim();

        DateTime? publishedAt;
        if (item['published_at'] != null) {
          publishedAt = DateTime.tryParse(item['published_at'] as String);
        }

        // Extract APK asset
        final assets = (item['assets'] as List<dynamic>? ?? []);
        String? apkDownloadUrl;
        String? apkFileName;
        int apkSize = 0;

        for (final asset in assets) {
          final name = (asset['name'] as String? ?? '').trim();
          if (name.toLowerCase().endsWith('.apk')) {
            apkDownloadUrl = asset['browser_download_url'] as String?;
            apkFileName = name;
            apkSize = (asset['size'] as num? ?? 0).toInt();
            break;
          }
        }

        releases.add(
          GitHubReleaseItem(
            tagName: tagName,
            releaseName: releaseName.isEmpty ? tagName : releaseName,
            changelog: changelog,
            apkDownloadUrl: apkDownloadUrl,
            apkFileName: apkFileName,
            apkSizeBytes: apkSize,
            publishedAt: publishedAt,
            isPrerelease: isPrerelease,
            isDraft: isDraft,
            htmlUrl: htmlUrl,
          ),
        );
      }

      return releases;
    } catch (e) {
      debugPrint('[UpdateService] Error fetching all releases: $e');
      return [];
    }
  }

  /// Compares remote tag (e.g. "v1.0.3") with local version (e.g. "1.0.2")
  static bool _isRemoteNewer({
    required String remoteTag,
    required String currentVersion,
    required String currentBuild,
  }) {
    return compareVersion(remoteTag, currentVersion, currentBuild) > 0;
  }

  /// Compares remote tag with current version.
  /// Returns:
  ///   1 if remote is newer than current
  ///   0 if remote is identical to current
  ///  -1 if remote is older than current (rollback / downgrade)
  static int compareVersion(
    String remoteTag,
    String currentVersion, [
    String currentBuild = '',
  ]) {
    final cleanRemote = remoteTag.replaceAll(RegExp(r'^[vV]'), '').trim();
    final cleanCurrent = currentVersion.replaceAll(RegExp(r'^[vV]'), '').trim();

    // Extract version part and build number
    final remoteParts = cleanRemote.split('+');
    final remoteSemver = remoteParts[0]
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final remoteBuild = remoteParts.length > 1
        ? (int.tryParse(remoteParts[1]) ?? 0)
        : 0;

    final currentParts = cleanCurrent.split('+');
    final currentSemver = currentParts[0]
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final localBuild = currentParts.length > 1
        ? (int.tryParse(currentParts[1]) ?? 0)
        : (int.tryParse(currentBuild) ?? 0);

    // Pad to 3 components (major.minor.patch)
    while (remoteSemver.length < 3) {
      remoteSemver.add(0);
    }
    while (currentSemver.length < 3) {
      currentSemver.add(0);
    }

    for (int i = 0; i < 3; i++) {
      if (remoteSemver[i] > currentSemver[i]) return 1;
      if (remoteSemver[i] < currentSemver[i]) return -1;
    }

    // If semver is identical, compare build number if specified
    if (remoteBuild > 0 && localBuild > 0) {
      if (remoteBuild > localBuild) return 1;
      if (remoteBuild < localBuild) return -1;
    }

    return 0;
  }

  /// Starts downloading the APK and triggers Android's package installer.
  Stream<OtaEvent> startOtaUpdate(String downloadUrl, {String? filename}) {
    if (kIsWeb || !Platform.isAndroid) {
      throw UnsupportedError(
        'OTA updates via APK are only supported on Android.',
      );
    }
    return OtaUpdate().execute(
      downloadUrl,
      destinationFilename: filename ?? 'music_app_latest.apk',
    );
  }
}
