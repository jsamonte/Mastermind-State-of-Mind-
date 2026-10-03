import 'package:flutter/material.dart';

import '../models.dart';

/// Heist palette. Vault gold on charcoal, with the three verdict colours doing
/// the real signalling work.
abstract final class Palette {
  static const bg = Color(0xFF0E0F13);
  static const surface = Color(0xFF171922);
  static const surfaceAlt = Color(0xFF1F222E);
  static const gold = Color(0xFFE8B931);
  static const green = Color(0xFF3DDC84);
  static const amber = Color(0xFFFFB020);
  static const red = Color(0xFFFF5A5A);
  static const muted = Color(0xFF8A90A6);

  static Color forVerdict(Verdict v) => switch (v) {
        Verdict.green => green,
        Verdict.amber => amber,
        Verdict.red => red,
        Verdict.inconclusive => muted,
      };
}
