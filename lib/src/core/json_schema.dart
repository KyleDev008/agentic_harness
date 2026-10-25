/// Result of [validateJsonSchema]: the (possibly coerced) value plus any
/// violations, as human-readable paths the model can act on.
final class SchemaValidation {
  final Object? value;
  final List<String> errors;
  const SchemaValidation(this.value, this.errors);
  bool get isValid => errors.isEmpty;
}

/// Validates [value] against a JSON Schema subset, coercing obvious
/// scalar mismatches first.
///
/// Supported keywords: `type` (string or list), `properties`, `required`,
/// `additionalProperties` (bool), `items`, `enum`, `const`, `minimum`,
/// `maximum`, `minLength`, `maxLength`, `minItems`, `maxItems`, `anyOf`,
/// `oneOf` (treated as anyOf). Unknown keywords are ignored, so any valid
/// schema can be passed — it is simply checked less strictly.
///
/// Coercions (models routinely send these): `"5"` → 5 for number/integer,
/// `"true"`/`"false"` → bool, `5.0` → 5 for integer, and a JSON-encoded
/// string for an object/array property is decoded by the caller beforehand
/// if desired — this function never parses JSON.
SchemaValidation validateJsonSchema(
  Object? value,
  Map<String, Object?> schema,
) {
  final errors = <String>[];
  final coerced = _validate(value, schema, r'$', errors);
  return SchemaValidation(coerced, errors);
}

Object? _validate(
  Object? value,
  Map<String, Object?> schema,
  String path,
  List<String> errors,
) {
  final anyOf = schema['anyOf'] ?? schema['oneOf'];
  if (anyOf is List && anyOf.isNotEmpty) {
    for (final option in anyOf) {
      if (option is! Map) continue;
      final branchErrors = <String>[];
      final result = _validate(
        value,
        option.cast<String, Object?>(),
        path,
        branchErrors,
      );
      if (branchErrors.isEmpty) return result;
    }
    errors.add('$path does not match any allowed shape');
    return value;
  }

  var current = value;
  final types = _types(schema['type']);
  if (types.isNotEmpty) {
    current = _coerce(current, types);
    if (!types.any((t) => _matchesType(current, t))) {
      errors.add(
        '$path must be ${types.join(' or ')}, got ${_typeName(current)}',
      );
      return current;
    }
  }

  final enumValues = schema['enum'];
  if (enumValues is List && !enumValues.contains(current)) {
    errors.add('$path must be one of ${enumValues.join(', ')}');
  }
  if (schema.containsKey('const') && schema['const'] != current) {
    errors.add('$path must equal ${schema['const']}');
  }

  if (current is num) {
    final min = schema['minimum'];
    final max = schema['maximum'];
    if (min is num && current < min) errors.add('$path must be >= $min');
    if (max is num && current > max) errors.add('$path must be <= $max');
  }
  if (current is String) {
    final minLen = schema['minLength'];
    final maxLen = schema['maxLength'];
    if (minLen is int && current.length < minLen) {
      errors.add('$path must have at least $minLen characters');
    }
    if (maxLen is int && current.length > maxLen) {
      errors.add('$path must have at most $maxLen characters');
    }
  }
  if (current is List) {
    final minItems = schema['minItems'];
    final maxItems = schema['maxItems'];
    if (minItems is int && current.length < minItems) {
      errors.add('$path must have at least $minItems items');
    }
    if (maxItems is int && current.length > maxItems) {
      errors.add('$path must have at most $maxItems items');
    }
    final items = schema['items'];
    if (items is Map) {
      final itemSchema = items.cast<String, Object?>();
      current = [
        for (var i = 0; i < current.length; i++)
          _validate(current[i], itemSchema, '$path[$i]', errors),
      ];
    }
  }
  if (current is Map) {
    final map = current.cast<String, Object?>();
    final out = <String, Object?>{...map};
    final props = schema['properties'];
    final propSchemas =
        props is Map
            ? props.cast<String, Object?>()
            : const <String, Object?>{};
    final required = schema['required'];
    if (required is List) {
      for (final key in required) {
        if (key is String && (!map.containsKey(key) || map[key] == null)) {
          errors.add('$path.$key is required');
        }
      }
    }
    for (final entry in map.entries) {
      final propSchema = propSchemas[entry.key];
      if (propSchema is Map) {
        // A null optional property is treated as absent.
        if (entry.value == null &&
            !(required is List && required.contains(entry.key))) {
          continue;
        }
        out[entry.key] = _validate(
          entry.value,
          propSchema.cast<String, Object?>(),
          '$path.${entry.key}',
          errors,
        );
      } else if (schema['additionalProperties'] == false) {
        errors.add('$path.${entry.key} is not an allowed property');
      }
    }
    current = out;
  }
  return current;
}

List<String> _types(Object? raw) {
  if (raw is String) return [raw];
  if (raw is List) return raw.whereType<String>().toList();
  return const [];
}

Object? _coerce(Object? value, List<String> types) {
  if (types.any((t) => _matchesType(value, t))) return value;
  if (value is String) {
    final trimmed = value.trim();
    if (types.contains('integer')) {
      final parsed = int.tryParse(trimmed);
      if (parsed != null) return parsed;
    }
    if (types.contains('number')) {
      final parsed = num.tryParse(trimmed);
      if (parsed != null) return parsed;
    }
    if (types.contains('boolean')) {
      final lower = trimmed.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
  }
  if (value is double &&
      types.contains('integer') &&
      value == value.truncate()) {
    return value.toInt();
  }
  if (value is num && types.contains('string')) return value.toString();
  if (value is bool && types.contains('string')) return value.toString();
  return value;
}

bool _matchesType(Object? value, String type) => switch (type) {
  'string' => value is String,
  'number' => value is num,
  'integer' => value is int || (value is double && value == value.truncate()),
  'boolean' => value is bool,
  'object' => value is Map,
  'array' => value is List,
  'null' => value == null,
  _ => true,
};

String _typeName(Object? value) => switch (value) {
  null => 'null',
  String() => 'string',
  int() => 'integer',
  num() => 'number',
  bool() => 'boolean',
  Map() => 'object',
  List() => 'array',
  _ => value.runtimeType.toString(),
};
