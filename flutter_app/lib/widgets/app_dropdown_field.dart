import 'package:flutter/material.dart';

export 'app_form_style.dart';

/// Keeps Flutter's selection, validation and keyboard behavior while matching
/// the app's rounded menus. The popup surface follows ThemeData.canvasColor.
class AppDropdownButtonFormField<T> extends DropdownButtonFormField<T> {
  AppDropdownButtonFormField({
    super.key,
    required super.items,
    required super.onChanged,
    T? initialValue,
    T? value,
    super.decoration,
    super.validator,
    super.onSaved,
    super.autovalidateMode,
    super.selectedItemBuilder,
    super.hint,
    super.disabledHint,
    super.onTap,
    super.focusNode,
    super.autofocus,
    super.isExpanded = true,
    super.isDense = true,
    super.style,
  }) : super(
         initialValue: initialValue ?? value,
         icon: const Icon(Icons.keyboard_arrow_down_rounded),
         iconSize: 20,
         borderRadius: BorderRadius.circular(16),
         menuMaxHeight: 360,
         elevation: 4,
       );
}
