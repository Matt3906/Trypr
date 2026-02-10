import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Trypr Design System
/// Inspired by modern, welcoming travel app aesthetics
/// - Soft sky blue accents
/// - Pure white cards with subtle shadows
/// - Generous spacing and large rounded corners
/// - Clean, friendly typography

class TryprColors {
  TryprColors._();

  // Primary - Soft Sky Blue (from reference design)
  static const Color primary = Color(0xFF4AADE8);
  static const Color primaryLight = Color(0xFF7BC4EF);
  static const Color primaryDark = Color(0xFF2E95D6);

  // Secondary - Soft Teal (your existing brand)
  static const Color secondary = Color(0xFF00897B);
  static const Color secondaryLight = Color(0xFF4DB6AC);

  // Backgrounds
  static const Color background = Color(0xFFF8FAFC);
  static const Color surface = Colors.white;
  static const Color surfaceVariant = Color(0xFFF1F5F9);

  // Text
  static const Color textPrimary = Color(0xFF1E293B);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color textTertiary = Color(0xFF94A3B8);

  // Accent colors for categories
  static const Color coral = Color(0xFFFF7F6B);
  static const Color mint = Color(0xFF4ECDC4);
  static const Color lavender = Color(0xFFA78BFA);
  static const Color peach = Color(0xFFFFB17A);
  static const Color rose = Color(0xFFFB7185);

  // Status
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);

  // Shadows
  static List<BoxShadow> get softShadow => [
    BoxShadow(
      color: Colors.black.withOpacity(0.04),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
    BoxShadow(
      color: Colors.black.withOpacity(0.02),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  static List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: Colors.black.withOpacity(0.06),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> get elevatedShadow => [
    BoxShadow(
      color: Colors.black.withOpacity(0.08),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
    BoxShadow(
      color: Colors.black.withOpacity(0.04),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
  ];
}

class TryprSpacing {
  TryprSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

class TryprRadius {
  TryprRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double full = 999;
}

class TryprTheme {
  TryprTheme._();

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: TryprColors.primary,
        brightness: Brightness.light,
        primary: TryprColors.primary,
        onPrimary: Colors.white,
        secondary: TryprColors.secondary,
        onSecondary: Colors.white,
        surface: TryprColors.surface,
        onSurface: TryprColors.textPrimary,
        error: TryprColors.error,
      ),
      scaffoldBackgroundColor: TryprColors.background,
      textTheme: _textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: TryprColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: TryprColors.textPrimary),
      ),
      cardTheme: CardThemeData(
        color: TryprColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TryprRadius.lg),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TryprColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(
            horizontal: TryprSpacing.xl,
            vertical: TryprSpacing.lg,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TryprRadius.md),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TryprColors.primary,
          padding: const EdgeInsets.symmetric(
            horizontal: TryprSpacing.xl,
            vertical: TryprSpacing.lg,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TryprRadius.md),
          ),
          side: const BorderSide(color: TryprColors.primary, width: 1.5),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: TryprColors.primary,
          padding: const EdgeInsets.symmetric(
            horizontal: TryprSpacing.lg,
            vertical: TryprSpacing.sm,
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: TryprColors.surfaceVariant,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: TryprSpacing.lg,
          vertical: TryprSpacing.lg,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TryprRadius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TryprRadius.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TryprRadius.md),
          borderSide: const BorderSide(color: TryprColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TryprRadius.md),
          borderSide: const BorderSide(color: TryprColors.error, width: 1),
        ),
        hintStyle: const TextStyle(
          color: TryprColors.textTertiary,
          fontSize: 15,
        ),
        labelStyle: const TextStyle(
          color: TryprColors.textSecondary,
          fontSize: 15,
        ),
        prefixIconColor: TryprColors.textSecondary,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: TryprColors.surfaceVariant,
        labelStyle: const TextStyle(
          color: TryprColors.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: TryprSpacing.md,
          vertical: TryprSpacing.sm,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TryprRadius.full),
        ),
        side: BorderSide.none,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: TryprColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TryprRadius.xl),
        ),
        titleTextStyle: const TextStyle(
          color: TryprColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: TryprColors.textPrimary,
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TryprRadius.md),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE2E8F0),
        thickness: 1,
        space: 1,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: TryprColors.surface,
        selectedItemColor: TryprColors.primary,
        unselectedItemColor: TryprColors.textTertiary,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: TryprColors.primary,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TryprRadius.lg),
        ),
      ),
    );
  }

  static TextTheme get _textTheme {
    return GoogleFonts.interTextTheme().copyWith(
      displayLarge: GoogleFonts.inter(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: TryprColors.textPrimary,
        letterSpacing: -0.5,
      ),
      displayMedium: GoogleFonts.inter(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: TryprColors.textPrimary,
        letterSpacing: -0.5,
      ),
      displaySmall: GoogleFonts.inter(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: TryprColors.textPrimary,
      ),
      headlineMedium: GoogleFonts.inter(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: TryprColors.textPrimary,
      ),
      headlineSmall: GoogleFonts.inter(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: TryprColors.textPrimary,
      ),
      titleLarge: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: TryprColors.textPrimary,
      ),
      titleMedium: GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: TryprColors.textPrimary,
      ),
      titleSmall: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: TryprColors.textSecondary,
      ),
      bodyLarge: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: TryprColors.textPrimary,
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: TryprColors.textSecondary,
      ),
      bodySmall: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: TryprColors.textTertiary,
      ),
      labelLarge: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: TryprColors.textPrimary,
      ),
      labelMedium: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: TryprColors.textSecondary,
      ),
      labelSmall: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: TryprColors.textTertiary,
        letterSpacing: 0.5,
      ),
    );
  }
}

// ============================================================================
// Reusable Styled Widgets
// ============================================================================

/// Soft card with subtle shadow - matches reference design
class SoftCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final Color? color;
  final VoidCallback? onTap;
  final bool elevated;

  const SoftCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = TryprRadius.lg,
    this.color,
    this.onTap,
    this.elevated = false,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: margin,
      decoration: BoxDecoration(
        color: color ?? TryprColors.surface,
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow:
            elevated ? TryprColors.elevatedShadow : TryprColors.softShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Material(
          color: Colors.transparent,
          child:
              onTap != null
                  ? InkWell(
                    onTap: onTap,
                    borderRadius: BorderRadius.circular(borderRadius),
                    child: Padding(
                      padding: padding ?? EdgeInsets.zero,
                      child: child,
                    ),
                  )
                  : Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      ),
    );

    return card;
  }
}

/// Trip card matching the reference design style
class TripCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? imageUrl;
  final List<String>? avatars;
  final String? location;
  final VoidCallback? onTap;

  const TripCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.imageUrl,
    this.avatars,
    this.location,
    this.onTap,
  });

  @override
  State<TripCard> createState() => _TripCardState();
}

class _TripCardState extends State<TripCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 200),
        scale: _isHovered ? 1.02 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: TryprColors.surface,
            borderRadius: BorderRadius.circular(TryprRadius.xl),
            boxShadow:
                _isHovered
                    ? TryprColors.elevatedShadow
                    : TryprColors.softShadow,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(TryprRadius.xl),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onTap,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Image section
                    AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          widget.imageUrl != null
                              ? Image.network(
                                widget.imageUrl!,
                                fit: BoxFit.cover,
                                errorBuilder:
                                    (_, __, ___) => Container(
                                      color: TryprColors.surfaceVariant,
                                      child: const Icon(
                                        Icons.image_outlined,
                                        size: 48,
                                        color: TryprColors.textTertiary,
                                      ),
                                    ),
                              )
                              : Container(
                                color: TryprColors.surfaceVariant,
                                child: const Icon(
                                  Icons.image_outlined,
                                  size: 48,
                                  color: TryprColors.textTertiary,
                                ),
                              ),
                        ],
                      ),
                    ),
                    // Content section
                    Padding(
                      padding: const EdgeInsets.all(TryprSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.location != null)
                            Row(
                              children: [
                                const Icon(
                                  Icons.location_on,
                                  size: 14,
                                  color: TryprColors.primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  widget.location!,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: TryprColors.textSecondary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const Spacer(),
                                if (widget.avatars != null &&
                                    widget.avatars!.isNotEmpty)
                                  _buildAvatarStack(),
                              ],
                            )
                          else
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: TryprColors.textPrimary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (widget.avatars != null &&
                                    widget.avatars!.isNotEmpty)
                                  _buildAvatarStack(),
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

  Widget _buildAvatarStack() {
    final avatars = widget.avatars!.take(3).toList();
    return SizedBox(
      height: 28,
      width: 28 + (avatars.length - 1) * 16.0,
      child: Stack(
        children: [
          for (var i = 0; i < avatars.length; i++)
            Positioned(
              left: i * 16.0,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  color: TryprColors.primary.withOpacity(0.2),
                ),
                child: ClipOval(
                  child:
                      avatars[i].startsWith('http')
                          ? Image.network(avatars[i], fit: BoxFit.cover)
                          : Center(
                            child: Text(
                              avatars[i].isNotEmpty
                                  ? avatars[i][0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: TryprColors.primary,
                              ),
                            ),
                          ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Location pill tag (like in reference design)
class LocationPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onTap;

  const LocationPill({
    super.key,
    required this.label,
    this.icon = Icons.location_on,
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pillColor = color ?? TryprColors.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: TryprSpacing.md,
          vertical: TryprSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: pillColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(TryprRadius.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: pillColor),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: pillColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Primary button with gradient effect
class PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? icon;
  final bool fullWidth;

  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.isLoading = false,
    this.icon,
    this.fullWidth = false,
  });

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: widget.fullWidth ? double.infinity : null,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _isHovered ? TryprColors.primaryDark : TryprColors.primary,
              _isHovered ? TryprColors.primary : TryprColors.primaryLight,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(TryprRadius.md),
          boxShadow: [
            BoxShadow(
              color: TryprColors.primary.withOpacity(_isHovered ? 0.4 : 0.25),
              blurRadius: _isHovered ? 12 : 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.isLoading ? null : widget.onPressed,
            borderRadius: BorderRadius.circular(TryprRadius.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: TryprSpacing.xl,
                vertical: TryprSpacing.lg,
              ),
              child:
                  widget.isLoading
                      ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                      : Row(
                        mainAxisSize:
                            widget.fullWidth
                                ? MainAxisSize.max
                                : MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (widget.icon != null) ...[
                            Icon(widget.icon, size: 18, color: Colors.white),
                            const SizedBox(width: TryprSpacing.sm),
                          ],
                          Text(
                            widget.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Section header with see-all action
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  final String seeAllText;

  const SectionHeader({
    super.key,
    required this.title,
    this.onSeeAll,
    this.seeAllText = 'See all',
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: TryprColors.textPrimary,
          ),
        ),
        if (onSeeAll != null)
          GestureDetector(
            onTap: onSeeAll,
            child: Row(
              children: [
                Text(
                  seeAllText,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: TryprColors.primary,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: TryprColors.primary,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Avatar with ring (like in reference)
class AvatarWithRing extends StatelessWidget {
  final String? imageUrl;
  final String initials;
  final double size;
  final Color? ringColor;
  final VoidCallback? onTap;

  const AvatarWithRing({
    super.key,
    this.imageUrl,
    required this.initials,
    this.size = 44,
    this.ringColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = ringColor ?? TryprColors.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size + 4,
        height: size + 4,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [color, color.withOpacity(0.6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(2),
        child: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
          ),
          padding: const EdgeInsets.all(2),
          child: ClipOval(
            child:
                imageUrl != null && imageUrl!.isNotEmpty
                    ? Image.network(
                      imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildInitials(),
                    )
                    : _buildInitials(),
          ),
        ),
      ),
    );
  }

  Widget _buildInitials() {
    return Container(
      color: TryprColors.surfaceVariant,
      child: Center(
        child: Text(
          initials.isNotEmpty ? initials[0].toUpperCase() : '?',
          style: TextStyle(
            fontSize: size * 0.4,
            fontWeight: FontWeight.w600,
            color: TryprColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
