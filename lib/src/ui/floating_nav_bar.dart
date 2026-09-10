// Floating rounded bottom navigation for the app shell.
//
// The bar floats above the page content (Scaffold.extendBody) using the app's
// glassmorphism treatment: blurred translucent capsule, gradient pill for the
// selected destination, and transfer count badges.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme.dart';

/// Height of the capsule itself (excluding safe-area and margin).
const double kFloatingNavBarHeight = 64;

/// Gap between the capsule and the bottom safe area.
const double kFloatingNavBarBottomMargin = 10;

/// Bottom padding scrollable screens should keep so the last item clears the
/// floating bar on devices with (and without) a home indicator.
const double kFloatingNavBarClearance = 120;

/// Screens that take over the bottom of the screen (e.g. the browser's
/// multi-select actions) set this to false so the shell hides the bar.
final shellNavVisibleProvider = StateProvider<bool>((ref) => true);

@immutable
class FloatingNavDestination {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int badgeCount;

  const FloatingNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeCount = 0,
  });
}

class FloatingNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<FloatingNavDestination> destinations;

  const FloatingNavBar({
    super.key,
    required this.currentIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(kFloatingNavBarHeight / 2);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          16,
          0,
          16,
          kFloatingNavBarBottomMargin,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.45 : 0.14),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                height: kFloatingNavBarHeight,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: radius,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: dark
                        ? [
                            Colors.white.withValues(alpha: 0.16),
                            Colors.white.withValues(alpha: 0.06),
                          ]
                        : [
                            Colors.white.withValues(alpha: 0.92),
                            Colors.white.withValues(alpha: 0.72),
                          ],
                  ),
                  border: Border.all(
                    color: dark
                        ? Colors.white.withValues(alpha: 0.20)
                        : Colors.white,
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    for (var i = 0; i < destinations.length; i++)
                      Expanded(
                        child: _NavItem(
                          destination: destinations[i],
                          selected: i == currentIndex,
                          onTap: () => onDestinationSelected(i),
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

class _NavItem extends StatelessWidget {
  final FloatingNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final idleColor = scheme.onSurface.withValues(alpha: 0.62);
    return Semantics(
      selected: selected,
      button: true,
      label: destination.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: selected ? 1 : 0),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          builder: (context, t, _) {
            final contentColor = Color.lerp(idleColor, Colors.white, t)!;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(99),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.teal.withValues(alpha: t),
                    AppColors.indigo.withValues(alpha: t),
                  ],
                ),
                boxShadow: t == 0
                    ? null
                    : [
                        BoxShadow(
                          color: AppColors.teal.withValues(alpha: 0.35 * t),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          selected
                              ? destination.selectedIcon
                              : destination.icon,
                          key: ValueKey(selected),
                          size: 22,
                          color: contentColor,
                        ),
                      ),
                      if (destination.badgeCount > 0)
                        Positioned(
                          top: -5,
                          right: -12,
                          child: _NavBadge(count: destination.badgeCount),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: contentColor,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NavBadge extends StatelessWidget {
  final int count;
  const _NavBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 17),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
      decoration: BoxDecoration(
        color: const Color(0xFFFF8A3D),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: Colors.white, width: 1.2),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 9 ? '9+' : '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          height: 1.2,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
