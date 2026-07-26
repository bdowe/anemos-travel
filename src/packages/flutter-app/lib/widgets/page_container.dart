import 'package:flutter/material.dart';

/// Centers page content and caps its width on wide (web/desktop) layouts.
///
/// Place it *inside* the scroll view, around the content column, so the
/// scrollable region stays full-width (mouse wheel and scrollbar keep working
/// in the gutters) while the content is constrained. The house width tiers:
/// 700 (default, reading/list pages), 760 (chat column), 900 (dense pages
/// like trip detail).
class PageContainer extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const PageContainer({super.key, required this.child, this.maxWidth = 700});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
