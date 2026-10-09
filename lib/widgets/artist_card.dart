import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/dynamic_artist_service.dart';
import 'dilse_image.dart';

/// Card widget representing an Artist in the Search screen.
/// Matches CategoryCard's visual design, dimensions, and micro-interactions,
/// with full image fill, dark gradient overlay, bold artist name, and famous genre subtitle.
class ArtistCard extends StatefulWidget {
  final ArtistItem artist;
  final VoidCallback onTap;

  const ArtistCard({super.key, required this.artist, required this.onTap});

  @override
  State<ArtistCard> createState() => _ArtistCardState();
}

class _ArtistCardState extends State<ArtistCard> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final scale = _isPressed ? 0.96 : (_isHovered ? 1.025 : 1.0);
    final primaryColor = Theme.of(context).primaryColor;

    return RepaintBoundary(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) {
            setState(() => _isPressed = false);
            HapticFeedback.lightImpact();
            widget.onTap();
          },
          onTapCancel: () => setState(() => _isPressed = false),
          child: AnimatedScale(
            scale: scale,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _isHovered
                      ? Colors.white.withValues(alpha: 0.45)
                      : Colors.white.withValues(alpha: 0.16),
                  width: _isHovered ? 1.4 : 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: _isHovered ? 0.65 : 0.40,
                    ),
                    blurRadius: _isHovered ? 18 : 10,
                    offset: Offset(0, _isHovered ? 8 : 4),
                  ),
                  if (_isHovered)
                    BoxShadow(
                      color: primaryColor.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  children: [
                    // 1. Background: Artist photo filled in the box
                    Positioned.fill(
                      child: DilSeImage(
                        imageUrl: widget.artist.imageUrl,
                        fit: BoxFit.cover,
                        errorWidget: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF232336), Color(0xFF13131D)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.person_rounded,
                              size: 44,
                              color: Colors.white24,
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 2. High-grade dark gradient tint for crystal-clear readability
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.22),
                              Colors.black.withValues(alpha: 0.46),
                              Colors.black.withValues(alpha: 0.92),
                            ],
                            stops: const [0.0, 0.45, 1.0],
                          ),
                        ),
                      ),
                    ),

                    // 3. Inner diagonal gloss shine on hover
                    Positioned.fill(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 250),
                        opacity: _isHovered ? 0.14 : 0.0,
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topRight,
                              end: Alignment.bottomLeft,
                              colors: [Colors.white, Colors.transparent],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 4. Card Content: Top header badge & Bottom text
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Top Header: Badge + Hover Play Micro-Button
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Frosted Artist Pill Badge
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.45),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.20),
                                    width: 0.8,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      widget.artist.isFromUserHistory
                                          ? Icons.star_rounded
                                          : Icons.local_fire_department_rounded,
                                      size: 11,
                                      color: widget.artist.isFromUserHistory
                                          ? const Color(0xFFFFD700)
                                          : Colors.white.withValues(
                                              alpha: 0.95,
                                            ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      widget.artist.badge,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Micro Hover Play Trigger
                              AnimatedOpacity(
                                duration: const Duration(milliseconds: 180),
                                opacity: _isHovered ? 1.0 : 0.0,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.35),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),

                          // Bottom Titles: Name in bold letters, Genre in small letters
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.artist.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.artist.genre,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.85),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
