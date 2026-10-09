import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Industrial-grade, memory-capped, disk-cached image renderer.
///
/// Automatically uses [CachedNetworkImage] for HTTP/HTTPS endpoints,
/// falling back safely to local disk files or asset bundles.
class DilSeImage extends StatelessWidget {
  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final bool enableMemoryCap;

  const DilSeImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.enableMemoryCap = true,
  });

  @override
  Widget build(BuildContext context) {
    final cleanUrl = imageUrl.trim();

    Widget content;
    if (cleanUrl.isEmpty) {
      content = errorWidget ?? _buildErrorWidget();
    } else if (cleanUrl.startsWith('http://') ||
        cleanUrl.startsWith('https://')) {
      final memWidth = (enableMemoryCap && width != null && width! > 0)
          ? (width! * 2).round()
          : null;
      final memHeight = (enableMemoryCap && height != null && height! > 0)
          ? (height! * 2).round()
          : null;

      content = CachedNetworkImage(
        imageUrl: cleanUrl,
        width: width,
        height: height,
        fit: fit,
        memCacheWidth: memWidth,
        memCacheHeight: memHeight,
        placeholder: (_, _) => placeholder ?? _buildPlaceholder(),
        errorWidget: (_, _, _) => errorWidget ?? _buildErrorWidget(),
      );
    } else if (!kIsWeb &&
        (cleanUrl.startsWith('/') ||
            cleanUrl.startsWith('file://') ||
            (cleanUrl.length > 2 && cleanUrl[1] == ':'))) {
      final path = cleanUrl.replaceFirst('file://', '');
      content = Image.file(
        File(path),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, _, _) => errorWidget ?? _buildErrorWidget(),
      );
    } else {
      content = Image.asset(
        cleanUrl,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, _, _) => errorWidget ?? _buildErrorWidget(),
      );
    }

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: content);
    }
    return content;
  }

  Widget _buildPlaceholder() {
    return Container(
      width: width,
      height: height,
      color: Colors.white.withValues(alpha: 0.05),
      child: const Center(
        child: Icon(Icons.image_outlined, color: Colors.white12, size: 20),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Container(
      width: width,
      height: height,
      color: Colors.white.withValues(alpha: 0.06),
      child: const Center(
        child: Icon(Icons.music_note_rounded, color: Colors.white38, size: 22),
      ),
    );
  }
}
