import 'dart:io';

/// Blocks requests to loopback, private, link-local, CGNAT, multicast and
/// unspecified addresses (SSRF protection), after DNS resolution.
///
/// Residual risk: the HTTP client re-resolves the host when connecting, so
/// a DNS-rebinding attacker controlling a short-TTL record could still
/// switch addresses between the check and the connection.
class NetGuard {
  /// Hosts allowed even when they resolve to blocked ranges (e.g. a local
  /// model server the user configured).
  final Set<String> allowHosts;

  const NetGuard({this.allowHosts = const {}});

  /// Throws [NetGuardViolation] when [uri] must not be fetched.
  Future<void> check(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw NetGuardViolation('only http/https URLs are allowed');
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty) throw NetGuardViolation('URL has no host');
    if (allowHosts.contains(host)) return;
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal')) {
      throw NetGuardViolation('local hosts are not allowed');
    }
    final literal = InternetAddress.tryParse(
      host.replaceAll(RegExp(r'^\[|\]$'), ''),
    );
    final addresses =
        literal != null ? [literal] : await InternetAddress.lookup(host);
    if (addresses.isEmpty) throw NetGuardViolation('host did not resolve');
    for (final address in addresses) {
      if (isBlocked(address)) {
        throw NetGuardViolation(
          'the host resolves to a private or local address',
        );
      }
    }
  }

  static bool isBlocked(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 192 && b[1] == 0 && b[2] == 0) ||
          (b[0] == 198 && (b[1] == 18 || b[1] == 19)) ||
          b[0] >= 224;
    }
    // IPv6: unspecified, unique-local fc00::/7, link-local fe80::/10,
    // IPv4-mapped (::ffff:a.b.c.d) checked as IPv4.
    if (b.every((x) => x == 0)) return true;
    if ((b[0] & 0xfe) == 0xfc) return true;
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true;
    final mapped =
        b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
    if (mapped) {
      return isBlocked(InternetAddress.fromRawAddress(b.sublist(12)));
    }
    return false;
  }
}

class NetGuardViolation implements Exception {
  final String message;
  NetGuardViolation(this.message);
  @override
  String toString() => message;
}
