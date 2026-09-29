// Error classes for the gateway client, ported from web client behaviour:
// only a confirmed 401 signs the user out; timeouts, 5xx and Cloudflare
// errors are connectivity problems (docs/CLIENTS.md).

/// Base class. Everything thrown by [GatewayClient] is one of these.
sealed class GatewayClientError implements Exception {
  const GatewayClientError(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Confirmed 401. The only error that signs the user out.
class AuthError extends GatewayClientError {
  const AuthError([super.message = 'The gateway rejected the token.']);
}

/// HTTP 429 with a retry window: the IP is locked out after failed auth
/// attempts (15 min). The gateway signals this with `retryAfterSec` in the
/// body and/or a `Retry-After` header; a bare 429 (session cap) is not one.
class LockedOut extends GatewayClientError {
  const LockedOut({this.retryAfterSec, String message = 'Too many attempts. Try again later.'})
      : super(message);
  final int? retryAfterSec;
}

/// Cloudflare answered 400 with an HTML body: the edge refused the request.
class EdgeRefused extends GatewayClientError {
  const EdgeRefused([super.message = 'The gateway edge refused the request.']);
}

/// The gateway answered with a JSON `{error}` body.
class GatewayError extends GatewayClientError {
  const GatewayError(this.status, super.message);
  final int status;
}

/// Socket failure, timeout, or a 5xx. Connectivity problem, not an auth one.
class Offline extends GatewayClientError {
  const Offline([super.message = 'Could not reach the gateway.']);
}

/// Maps an HTTP response to an error, shared by the client and its tests.
GatewayClientError errorForResponse({
  required int status,
  required String? contentType,
  required String bodyText,
  Map<String, dynamic>? json,
  Map<String, String> headers = const {},
}) {
  switch (status) {
    case 401:
      return const AuthError();
    case 429:
      // Auth lockout carries retryAfterSec in the body and/or a Retry-After
      // header. The session cap is a bare 429 with neither: a GatewayError.
      final retry = retryAfterSec(json, headers);
      if (retry != null) return LockedOut(retryAfterSec: retry);
      final msg = _errorMessage(json) ?? 'HTTP $status';
      return GatewayError(status, msg);
  }
  if (status == 400 && _looksLikeHtml(contentType, bodyText)) {
    return const EdgeRefused();
  }
  final msg = _errorMessage(json) ?? 'HTTP $status';
  if (status >= 500) return Offline(msg);
  return GatewayError(status, msg);
}

/// Retry window for a 429, in seconds: `retryAfterSec` from the JSON body,
/// else the integer `retry-after` response header.
int? retryAfterSec(Map<String, dynamic>? json, Map<String, String> headers) {
  if (json != null) {
    final v = json['retryAfterSec'];
    if (v is int) return v;
    if (v is num) return v.toInt();
  }
  final header = headers['retry-after'];
  if (header == null) return null;
  return int.tryParse(header.trim());
}

bool _looksLikeHtml(String? contentType, String bodyText) {
  if (contentType != null && contentType.toLowerCase().contains('text/html')) return true;
  final t = bodyText.trimLeft().toLowerCase();
  return t.startsWith('<!doctype') || t.startsWith('<html');
}

String? _errorMessage(Map<String, dynamic>? json) {
  if (json == null) return null;
  final err = json['error'];
  if (err is String && err.isNotEmpty) return err;
  final detail = json['detail'];
  if (detail is String && detail.isNotEmpty) return detail;
  // FastAPI 422 validation errors: detail is a list of {loc, msg} objects.
  if (detail is List && detail.isNotEmpty) {
    final first = detail.first;
    if (first is String && first.isNotEmpty) return first;
    if (first is Map) {
      final msg = first['msg'];
      if (msg is String && msg.isNotEmpty) return msg;
    }
  }
  return null;
}
