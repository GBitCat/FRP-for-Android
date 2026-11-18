import 'package:toml/toml.dart';

final _credentialKey = RegExp(
  r'key|password|passwd|secret|token|authorization|credential|cookie|sk$',
);

String _normalize(String key) =>
    key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

/// Both views use the parsed key path. FRP HTTP header entries use the value
/// of a sibling field ("name") as the key. Its position in TOML is immaterial.
String redactConfigurationToml(String source, {bool forExport = false}) {
  try {
    final doc = TomlDocument.parse(source);
    final redactor = _TomlRedactor(forExport);
    var table = TomlKey.topLevel;
    var privateHeader = false;
    final output = <TomlExpression>[];
    for (var i = 0; i < doc.expressions.length; i++) {
      final expression = doc.expressions[i];
      if (expression is TomlTable) {
        table = expression.name;
        privateHeader =
            _isHeaders(table) &&
            _privateHeader(
              doc.expressions
                  .skip(i + 1)
                  .takeWhile((e) => e is! TomlTable)
                  .whereType<TomlKeyValuePair>(),
            );
        output.add(expression);
      } else if (expression is TomlKeyValuePair) {
        output.add(
          redactor.field(table, expression, privateHeader: privateHeader),
        );
      }
    }
    // The parser excludes comments, which may themselves contain credentials.
    return TomlDocument(output).toString().trimRight();
  } on TomlException {
    // Parser diagnostics can include the actual configuration.
  } on StackOverflowError {
    // A deeply nested or invalid imported value must never fall back to raw text.
  }
  if (forExport) throw StateError('Unable to redact invalid TOML.');
  return '# Unparsed configuration value hidden';
}

bool _isHeaders(TomlKey key) =>
    key.parts.isNotEmpty && _normalize(key.childKey.name) == 'httpheaders';

bool _privateHeader(Iterable<TomlKeyValuePair> fields) {
  final names = fields.where(
    (item) =>
        item.key.parts.length == 1 &&
        _normalize(item.key.childKey.name) == 'name',
  );
  if (names.length != 1 || names.single.value is! TomlString) return true;
  final name = _normalize((names.single.value as TomlString).value);
  return name.isEmpty ||
      _credentialKey.hasMatch(name) ||
      name.contains('auth') ||
      name.contains('session') ||
      name.contains('signature');
}

class _TomlRedactor {
  _TomlRedactor(this.forExport);
  final bool forExport;

  TomlKeyValuePair field(
    TomlKey table,
    TomlKeyValuePair pair, {
    bool privateHeader = false,
  }) {
    final path = table.deepChild(pair.key);
    final normalized = path.parts.map((part) => _normalize(part.name));
    final value = pair.value;
    if (normalized.any(_credentialKey.hasMatch) ||
        (privateHeader && normalized.last == 'value')) {
      if (forExport && value is TomlArray) {
        throw StateError('Redacted export cannot preserve a credential array.');
      }
      return TomlKeyValuePair(
        pair.key,
        TomlBasicString(forExport ? '' : '***'),
      );
    }
    final result = _value(path, value);
    if (!forExport &&
        normalized.last == 'headers' &&
        value is TomlInlineTable &&
        result != value) {
      // Preserve the preview's conservative handling of arbitrary header maps.
      return TomlKeyValuePair(pair.key, TomlBasicString('***'));
    }
    return TomlKeyValuePair(pair.key, result);
  }

  TomlValue _value(TomlKey path, TomlValue value) {
    if (value is TomlArray) {
      return TomlArray(value.items.map((item) => _value(path, item)));
    }
    if (value is TomlInlineTable) {
      final header = _isHeaders(path);
      // Portable backups historically require non-header inline tables to be
      // expanded. An inline healthCheck can itself contain the header array.
      if (forExport && !header && !value.pairs.any((p) => _isHeaders(p.key))) {
        throw StateError(
          'Redacted export cannot safely process inline TOML tables. '
          'Expand them to separate assignments or use encrypted export.',
        );
      }
      final sensitive = header && _privateHeader(value.pairs);
      return TomlInlineTable(
        value.pairs.map((item) => field(path, item, privateHeader: sensitive)),
      );
    }
    return value;
  }
}
