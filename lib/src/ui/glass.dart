// Glassmorphism primitives: blurred translucent surfaces over a
// gradient backdrop. Used by every screen for a consistent modern look.

import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/s3/s3_account.dart';
import 'theme.dart';

/// Gradient backdrop with ambient color blobs. Wrap Scaffold bodies in this
/// (use extendBodyBehindAppBar + transparent AppBar for full-bleed glass).
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [AppColors.darkBg, AppColors.darkBg2]
                  : const [AppColors.lightBg, Color(0xFFE6F4F1)],
            ),
          ),
        ),
        if (dark) ...[
          Positioned(
            top: -120,
            right: -80,
            child: _Blob(
              size: 320,
              colors: [
                AppColors.teal.withValues(alpha: 0.28),
                Colors.transparent,
              ],
            ),
          ),
          Positioned(
            top: 220,
            left: -110,
            child: _Blob(
              size: 300,
              colors: [
                AppColors.violet.withValues(alpha: 0.24),
                Colors.transparent,
              ],
            ),
          ),
          Positioned(
            bottom: -140,
            right: 40,
            child: _Blob(
              size: 280,
              colors: [
                AppColors.indigo.withValues(alpha: 0.20),
                Colors.transparent,
              ],
            ),
          ),
        ] else ...[
          Positioned(
            top: -120,
            right: -80,
            child: _Blob(
              size: 320,
              colors: [
                AppColors.teal.withValues(alpha: 0.22),
                Colors.transparent,
              ],
            ),
          ),
          Positioned(
            bottom: -140,
            left: -60,
            child: _Blob(
              size: 300,
              colors: [
                AppColors.violet.withValues(alpha: 0.18),
                Colors.transparent,
              ],
            ),
          ),
        ],
        child,
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  final double size;
  final List<Color> colors;
  const _Blob({required this.size, required this.colors});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        height: size,
        width: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: colors),
        ),
      ),
    );
  }
}

/// Frosted-glass surface. [onTap] adds ink ripple affordance.
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double? blur;
  const Glass({
    super.key,
    required this.child,
    this.padding,
    this.radius = 20,
    this.onTap,
    this.onLongPress,
    this.blur,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    final surface = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur ?? 18, sigmaY: blur ?? 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? [
                      Colors.white.withValues(alpha: 0.13),
                      Colors.white.withValues(alpha: 0.05),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.75),
                      Colors.white.withValues(alpha: 0.45),
                    ],
            ),
            border: Border.all(
              color: dark
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.9),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.25 : 0.08),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
    if (onTap == null && onLongPress == null) return surface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        onLongPress: onLongPress,
        child: surface,
      ),
    );
  }
}

/// Gradient tile with the provider's initial — the account/bucket identity.
class ProviderBadge extends StatelessWidget {
  final ProviderType provider;
  final double size;
  const ProviderBadge({super.key, required this.provider, this.size = 48});

  List<Color> get _gradient {
    switch (provider) {
      case ProviderType.aws:
        return const [Color(0xFFFFB84D), AppColors.aws];
      case ProviderType.cloudflareR2:
        return const [Color(0xFFFBBF24), AppColors.r2];
      case ProviderType.minio:
        return const [Color(0xFFFB7185), AppColors.minio];
      case ProviderType.wasabi:
        return const [Color(0xFF5EEAD4), AppColors.wasabi];
      case ProviderType.backblazeB2:
        return const [Color(0xFFFCA5A5), AppColors.b2];
      case ProviderType.custom:
        return const [Color(0xFF94A3B8), AppColors.custom];
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = _gradient;
    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: g,
        ),
        boxShadow: [
          BoxShadow(
            color: g[1].withValues(alpha: 0.45),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        provider.label[0],
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}

/// Section label with letterspaced overline styling.
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 1.6,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface
              .withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// Friendly empty state with icon halo.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 96,
              width: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    scheme.primary.withValues(alpha: 0.35),
                    AppColors.violet.withValues(alpha: 0.35),
                  ],
                ),
              ),
              child: Icon(icon, size: 44, color: Colors.white),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.65)),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Pill status chip (transfers, connection state).
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const StatusPill({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Gradient-filled primary button with glow.
class GlowButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool filled;
  const GlowButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
    if (!filled) {
      return OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: radius),
          padding: EdgeInsets.zero,
        ),
        child: content,
      );
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: const LinearGradient(
          colors: [AppColors.teal, AppColors.indigo],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.teal.withValues(alpha: 0.4),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white),
            child: IconTheme(
              data: const IconThemeData(color: Colors.white),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
