import 'dart:math';

final Random _random = _secureOrFallback();

Random _secureOrFallback() {
  try {
    return Random.secure();
  } on UnsupportedError {
    return Random();
  }
}

const _alphabet =
    '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// A collision-resistant id such as `toolu_3fK9xQ2mL0aB7cD1eF4g`.
///
/// 20 random base-62 characters (~119 bits) — unlike timestamp ids, two
/// ids generated in the same millisecond never collide.
String newId(String prefix) {
  final buffer = StringBuffer(prefix)..write('_');
  for (var i = 0; i < 20; i++) {
    buffer.write(_alphabet[_random.nextInt(_alphabet.length)]);
  }
  return buffer.toString();
}
