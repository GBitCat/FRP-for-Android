import 'package:flutter/material.dart';

class ConfigSectionTitle extends StatelessWidget {
  final String title;

  const ConfigSectionTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) =>
      Text(title, style: Theme.of(context).textTheme.titleMedium);
}

class ConfigTextField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String label;
  final String? hint;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Widget? suffixIcon;

  const ConfigTextField({
    required this.controller,
    required this.onChanged,
    required this.label,
    super.key,
    this.hint,
    this.obscureText = false,
    this.keyboardType,
    this.suffixIcon,
  });

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: onChanged,
    obscureText: obscureText,
    keyboardType: keyboardType,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      suffixIcon: suffixIcon,
    ),
  );
}
