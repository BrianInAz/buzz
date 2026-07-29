import 'package:flutter/material.dart';

import '../theme/theme.dart';

const mobileTabBarHeight = 56.0;
const mobileTabBarBottomGap = Grid.twelve;

double mobileTabFooterBackdropHeight(BuildContext context) =>
    mobileTabBarHeight +
    mobileTabBarBottomGap +
    View.of(context).padding.bottom +
    Grid.xl +
    Grid.gutter;

/// Shared fade behind the floating mobile tab bar.
class MobileTabFooterBackdrop extends StatelessWidget {
  final double height;
  final List<double> stops;
  final List<double> opacities;

  const MobileTabFooterBackdrop({
    super.key,
    required this.height,
    this.stops = const [0, 0.5, 1],
    this.opacities = const [0, 0.75, 1],
  }) : assert(stops.length == opacities.length);

  @override
  Widget build(BuildContext context) {
    final surface = context.colors.surface;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: stops,
            colors: [
              for (final opacity in opacities)
                surface.withValues(alpha: opacity),
            ],
          ),
        ),
      ),
    );
  }
}
