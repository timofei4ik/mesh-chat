import 'dart:convert';

/// Versioned, insert-only Quill delta. The plain fallback is bound to the delta.
class RichMessageDocument {
  RichMessageDocument._(this.ops, this.text);
  static const maxBytes = 192 * 1024;
  static const maxTextLength = 60000;
  final List<Map<String, dynamic>> ops;
  final String text;

  String encode() => jsonEncode({'v': 1, 'ops': ops, 'text': text});

  Iterable<Map<String, dynamic>> get attachments sync* {
    for (final op in ops) {
      final insert = op['insert'];
      if (insert is Map && insert['mesh'] is String) {
        final data = validateEmbed(jsonDecode(insert['mesh'] as String));
        if (data['type'] == 'attachment') yield data;
      }
    }
  }

  RichMessageDocument replaceAttachmentIds(Map<String, String> replacements) =>
      fromOps([
        for (final op in ops)
          if (op['insert'] is Map && (op['insert'] as Map)['mesh'] is String)
            _replaceAttachment(op, replacements)
          else
            op,
      ]);

  static Map<String, dynamic> _replaceAttachment(
    Map<String, dynamic> op,
    Map<String, String> replacements,
  ) {
    final data = validateEmbed(
      jsonDecode((op['insert'] as Map)['mesh'] as String),
    );
    if (data['type'] != 'attachment' || !replacements.containsKey(data['id'])) {
      return op;
    }
    return {
      ...op,
      'insert': {
        'mesh': jsonEncode({...data, 'id': replacements[data['id']]}),
      },
    };
  }

  static Uri? safeLink(String value) {
    if (value.length > 2048 || RegExp(r'[\x00-\x20]').hasMatch(value)) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['https', 'http', 'mailto', 'tel'].contains(uri.scheme)) {
      return null;
    }
    if (['https', 'http'].contains(uri.scheme) &&
        (uri.host.isEmpty || uri.userInfo.isNotEmpty)) {
      return null;
    }
    return uri;
  }

  static RichMessageDocument? decode(String raw, {String? expectedText}) {
    if (raw.isEmpty || raw.length > maxBytes) return null;
    try {
      if (utf8.encode(raw).length > maxBytes) return null;
      final json = jsonDecode(raw);
      if (json is! Map || json['v'] != 1 || json['text'] is! String) {
        return null;
      }
      final document = fromOps(json['ops']);
      if (document.text != json['text'] ||
          (expectedText != null && document.text != expectedText.trim())) {
        return null;
      }
      return document;
    } catch (_) {
      return null;
    }
  }

  static RichMessageDocument fromText(String text) => fromOps([
    {'insert': '${text.trimRight()}\n'},
  ]);

  static List<Map<String, dynamic>> safePaste(List<dynamic> raw) {
    try {
      // Clipboard fragments do not need a final newline; documents do.
      fromOps([
        ...raw,
        {'insert': '\n'},
      ]);
      return raw.map((op) => Map<String, dynamic>.from(op as Map)).toList();
    } catch (_) {
      final text = StringBuffer();
      for (final op in raw.take(2000)) {
        if (op is! Map) continue;
        final insert = op['insert'];
        if (insert is String) {
          text.write(insert.replaceAll('\u0000', ''));
        } else if (insert is Map) {
          text.write('[Media]');
        }
        if (text.length >= maxTextLength) break;
      }
      final value = text.toString();
      return value.isEmpty
          ? []
          : [
              {
                'insert': value.length > maxTextLength
                    ? value.substring(0, maxTextLength)
                    : value,
              },
            ];
    }
  }

  static RichMessageDocument fromOps(dynamic raw) {
    if (raw is! List || raw.isEmpty || raw.length > 2000) {
      throw const FormatException('Invalid document');
    }
    final ops = <Map<String, dynamic>>[];
    final text = StringBuffer();
    var embeds = 0;
    for (final entry in raw) {
      if (entry is! Map ||
          entry.containsKey('delete') ||
          entry.containsKey('retain')) {
        throw const FormatException('Not a document');
      }
      final insert = entry['insert'];
      if (insert is String) {
        if (insert.isEmpty || insert.contains('\u0000')) {
          throw const FormatException('Invalid text');
        }
        text.write(insert);
      } else if (insert is Map && insert.length == 1 && ++embeds <= 64) {
        if (insert['formula'] is String) {
          final formula = insert['formula'] as String;
          if (formula.length > 512) {
            throw const FormatException('Formula too long');
          }
          text.write(formula);
        } else if (insert['mesh'] is String) {
          text.write(
            embedText(validateEmbed(jsonDecode(insert['mesh'] as String))),
          );
        } else {
          throw const FormatException('Unsupported embed');
        }
      } else {
        throw const FormatException('Invalid insertion');
      }
      if (text.length > maxTextLength) {
        throw const FormatException('Message too long');
      }
      final attributes = <String, dynamic>{};
      if (entry['attributes'] != null) {
        if (entry['attributes'] is! Map) {
          throw const FormatException('Invalid styles');
        }
        for (final attribute in (entry['attributes'] as Map).entries) {
          final k = attribute.key;
          final v = attribute.value;
          final valid = switch (k) {
            'bold' ||
            'italic' ||
            'underline' ||
            'strike' ||
            'code' ||
            'blockquote' ||
            'code-block' ||
            'small' => v is bool,
            'header' => v is int && v >= 1 && v <= 3,
            'indent' => v is int && v >= 0 && v <= 5,
            'list' => ['ordered', 'bullet', 'checked', 'unchecked'].contains(v),
            'script' => ['sub', 'super'].contains(v),
            'size' => ['small', 'large', 'huge'].contains(v),
            'align' => ['left', 'center', 'right', 'justify'].contains(v),
            'direction' => v == 'rtl',
            'background' ||
            'color' => v is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v),
            'link' => v is String && safeLink(v) != null,
            _ => false,
          };
          if (!valid) throw const FormatException('Unsupported style');
          attributes[k as String] = v;
        }
      }
      ops.add({
        'insert': insert,
        if (attributes.isNotEmpty) 'attributes': attributes,
      });
    }
    if (ops.last['insert'] is! String ||
        !(ops.last['insert'] as String).endsWith('\n')) {
      throw const FormatException('Missing final newline');
    }
    final result = RichMessageDocument._(ops, text.toString().trim());
    if (utf8.encode(result.encode()).length > maxBytes) {
      throw const FormatException('Document too large');
    }
    return result;
  }

  static Map<String, dynamic> validateEmbed(dynamic value) {
    if (value is! Map) throw const FormatException('Invalid embed');
    final data = Map<String, dynamic>.from(value);
    bool bounded(String key, int max) =>
        data[key] is String && (data[key] as String).length <= max;
    final valid = switch (data['type']) {
      'divider' => true,
      'spoiler' || 'pullquote' => bounded('text', 8000),
      'details' => bounded('title', 200) && bounded('text', 8000),
      'button' =>
        bounded('label', 200) &&
            bounded('url', 2048) &&
            safeLink(data['url'] as String) != null,
      'attachment' =>
        bounded('id', 120) &&
            RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(data['id'] as String) &&
            bounded('name', 200) &&
            (data['name'] as String).isNotEmpty,
      'location' =>
        data['lat'] is num &&
            data['lon'] is num &&
            (data['lat'] as num).isFinite &&
            (data['lon'] as num).isFinite &&
            (data['lat'] as num).abs() <= 90 &&
            (data['lon'] as num).abs() <= 180,
      'table' =>
        data['rows'] is List &&
            (data['rows'] as List).isNotEmpty &&
            (data['rows'] as List).length <= 20 &&
            (data['rows'] as List).every(
              (row) =>
                  row is List &&
                  row.isNotEmpty &&
                  row.length <= 8 &&
                  row.every((cell) => cell is String && cell.length <= 2000),
            ),
      _ => false,
    };
    if (!valid) throw const FormatException('Invalid embed content');
    return data;
  }

  static String embedText(Map<String, dynamic> data) => switch (data['type']) {
    'table' =>
      (data['rows'] as List).map((row) => (row as List).join(' | ')).join('\n'),
    'divider' => '---',
    'details' => '${data['title']}\n${data['text']}',
    'button' => '${data['label']} (${data['url']})',
    'attachment' => '[${data['name']}]',
    'location' =>
      'https://www.openstreetmap.org/?mlat=${data['lat']}&mlon=${data['lon']}',
    _ => data['text'] as String,
  };
}
