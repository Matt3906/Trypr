import 'package:flutter/material.dart';
import 'package:trypr/theme/app_theme.dart';

/// Gradient button with modern styling - Updated to use new Trypr theme
class GradientButton extends StatefulWidget {
  final VoidCallback onPressed;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  const GradientButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final visualScale = _isPressed ? 0.985 : (_isHovered ? 1.01 : 1.0);
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        scale: visualScale,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                _isHovered ? TryprColors.primaryDark : TryprColors.primary,
                _isHovered ? TryprColors.primary : TryprColors.primaryLight,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: widget.borderRadius,
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
              onTap: widget.onPressed,
              onTapDown: (_) => setState(() => _isPressed = true),
              onTapUp: (_) => setState(() => _isPressed = false),
              onTapCancel: () => setState(() => _isPressed = false),
              borderRadius: widget.borderRadius,
              child: Padding(
                padding: widget.padding,
                child: DefaultTextStyle(
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Soft card with subtle shadow - Updated to use new Trypr theme
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? backgroundColor;
  final Border? border;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = 16,
    this.backgroundColor,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor ?? TryprColors.surface,
        borderRadius: BorderRadius.circular(borderRadius),
        border: border,
        boxShadow: TryprColors.softShadow,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Avatar ring with gradient - Updated to use new Trypr theme
class AvatarRing extends StatelessWidget {
  final String initials;
  final double size;
  final Color? backgroundColor;
  final VoidCallback? onTap;
  final String? imageUrl;

  const AvatarRing({
    super.key,
    required this.initials,
    this.size = 48,
    this.backgroundColor,
    this.onTap,
    this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final color = backgroundColor ?? TryprColors.primary;
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
                      errorBuilder: (_, __, ___) => _buildInitials(color),
                    )
                    : _buildInitials(color),
          ),
        ),
      ),
    );
  }

  Widget _buildInitials(Color color) {
    return Container(
      color: TryprColors.surfaceVariant,
      child: Center(
        child: Text(
          initials.isNotEmpty ? initials[0].toUpperCase() : '?',
          style: TextStyle(
            fontSize: size * 0.4,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}
