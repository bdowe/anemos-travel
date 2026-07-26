import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// App bar painted with [AppColors.brandGradient] — the same teal pair used by
/// the home hero banner. Use in place of [AppBar] so every screen shares one
/// header look.
class GradientAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget title;
  final List<Widget>? actions;

  /// Null inherits the app-wide AppBarTheme (centered); the home screen passes
  /// false so the brand mark sits on the left.
  final bool? centerTitle;

  const GradientAppBar(
      {super.key, required this.title, this.actions, this.centerTitle});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: title,
      actions: actions,
      centerTitle: centerTitle,
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      flexibleSpace: Container(
        decoration: BoxDecoration(gradient: AppColors.brandGradient),
      ),
    );
  }
}
