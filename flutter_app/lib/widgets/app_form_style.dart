import 'package:flutter/material.dart';

/// Shared density for single-line fields. Helper/error text and multiline
/// editors are deliberately free to grow below the input.
abstract final class AppFormStyle {
  static const double controlHeight = 46;
  static const double fontSize = 16;
  static const contentPadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 11,
  );
  static const borderRadius = BorderRadius.all(Radius.circular(10));
  static const iconConstraints = BoxConstraints(
    minWidth: controlHeight,
    minHeight: controlHeight,
    maxHeight: controlHeight,
  );

  static InputDecoration decoration({
    String? label,
    String? hint,
    String? helper,
    String? error,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
    errorText: error,
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    isDense: true,
    contentPadding: contentPadding,
    prefixIconConstraints: iconConstraints,
    suffixIconConstraints: iconConstraints,
    border: const OutlineInputBorder(borderRadius: borderRadius),
  );
}
