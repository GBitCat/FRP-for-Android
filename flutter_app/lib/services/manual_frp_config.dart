import 'package:toml/toml.dart';

typedef ManualFrpBlock = ({String section, Map<String, dynamic> values});

/// Reads FRP's list of visitors and proxies using TOML's table, key and
/// string rules. Keep the caller's original document for editing and export.
List<ManualFrpBlock> manualFrpBlocks(String source) {
  final Map<String, dynamic> document;
  try {
    document = TomlDocument.parse(source).toMap();
  } on TomlException {
    // Parser diagnostics may include the source line and its credentials.
    throw const FormatException('Invalid manual TOML syntax');
  } on StackOverflowError {
    throw const FormatException('Manual TOML nesting is too deep');
  }
  final blocks = <ManualFrpBlock>[];
  for (final entry in document.entries) {
    if (entry.key != 'visitors' && entry.key != 'proxies') continue;
    final values = entry.value;
    if (values is! List ||
        values.any((value) => value is! Map<String, dynamic>)) {
      throw const FormatException(
        'Visitors and proxies must be arrays of TOML tables',
      );
    }
    for (final block in values.cast<Map<String, dynamic>>()) {
      blocks.add((section: entry.key, values: block));
    }
  }
  return blocks;
}
