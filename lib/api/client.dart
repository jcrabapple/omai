// The single HTTP client for the gateway, ported from web/src/lib/api/client.ts
// and endpoints.ts. No UI code talks to http directly. No Flutter imports.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'models.dart';

/// WebSocket probe used by the connection test, injected so tests can stub it.
/// Returns true when the socket opened and the server spoke (or closed it with
/// a code that proves the WS leg works, i.e. anything but no connection).
typedef WsProbe = Future<bool> Function(Uri uri, Map<String, String> headers);

class GatewayClient {
  GatewayClient({
    required String baseUrl,
    required this.token,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
       _client = client ?? http.Client();

  /// Base URL without trailing slashes; e.g. `https://gateway.example.com`.
  final String baseUrl;
  final String token;
  final Duration timeout;
  final http.Client _client;

  /// `ws(s)://` form of the base URL, for `/omp-ws/{id}`.
  Uri wsUrl(String path, [Map<String, String>? query]) {
    var ws = baseUrl.replaceFirst(RegExp('^http'), 'ws');
    final params = query == null || query.isEmpty ? '' : _queryString(query);
    return Uri.parse('$ws$path$params');
  }

  String _queryString(Map<String, String> query) =>
      Uri(queryParameters: query).query.isEmpty
      ? ''
      : '?${Uri(queryParameters: query).query}';

  Uri _uri(String path, [Map<String, String>? query]) {
    var suffix = '';
    if (query != null && query.isNotEmpty) suffix = _queryString(query);
    return Uri.parse('$baseUrl$path$suffix');
  }

  Map<String, String> _headers({bool jsonBody = false}) => {
    'Authorization': 'Bearer $token',
    if (jsonBody) 'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool rawBody = false,
    Duration? timeout,
  }) async {
    final String payload;
    final headers = _headers(jsonBody: !rawBody && body != null);
    if (body == null) {
      payload = '';
    } else if (rawBody && body is String) {
      payload = body;
    } else {
      payload = jsonEncode(body);
    }
    final request = http.Request(method, _uri(path, query))
      ..headers.addAll(headers)
      ..followRedirects = true;
    if (payload.isNotEmpty) request.body = payload;

    late http.Response res;
    try {
      final streamed = await _client
          .send(request)
          .timeout(timeout ?? this.timeout);
      res = await http.Response.fromStream(streamed)
          .timeout(timeout ?? this.timeout);
    } on TimeoutException {
      throw const Offline('The gateway did not answer in time.');
    } on SocketException {
      throw const Offline('Could not reach the gateway.');
    } catch (e) {
      if (e is GatewayClientError) rethrow;
      throw const Offline('Could not reach the gateway.');
    }

    final text = res.body;
    Map<String, dynamic>? json;
    if (text.isNotEmpty) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) json = decoded;
      } on FormatException {
        // Non-JSON body: falls through to the error mapping or a null result.
      }
    }

    if (res.statusCode >= 400) {
      throw errorForResponse(
        status: res.statusCode,
        contentType: res.headers['content-type'],
        bodyText: text,
        json: json,
        headers: res.headers,
      );
    }
    return json ?? const <String, dynamic>{};
  }

  // ---------------------------------------------------------------- host

  /// Public reachability check. `{"ok": true}`.
  Future<bool> healthz() async {
    final json = await _send('GET', '/healthz');
    return json['ok'] == true;
  }

  /// Gateway + omp liveness, live session count.
  Future<Map<String, dynamic>> health() => _send('GET', '/api/health');

  /// Cheap "am I signed in" check -> `{"method": "bearer"}`.
  Future<String> me() async {
    final json = await _send('GET', '/api/me');
    final method = json['method'];
    return method is String ? method : '';
  }

  Future<Map<String, dynamic>> system() => _send('GET', '/api/system');

  Future<CatalogModels> catalogModels({bool refresh = false}) async {
    final json = await _send(
      'GET',
      '/api/catalog/models',
      query: refresh ? {'refresh': '1'} : null,
      timeout: const Duration(minutes: 3),
    );
    return CatalogModels.fromJson(json);
  }

  Future<Map<String, dynamic>> skills() => _send('GET', '/api/skills');

  Future<Map<String, dynamic>> usage() =>
      _send('GET', '/api/usage', timeout: const Duration(minutes: 2));

  /// Escape hatch: any omp RpcCommand, returned as `{data}`.
  Future<Map<String, dynamic>> rpc(String id, Map<String, dynamic> command) =>
      _send(
        'POST',
        '/api/sessions/${Uri.encodeComponent(id)}/rpc',
        body: command,
      );

  // ------------------------------------------------------------- sessions

  Future<SessionsList> sessions({
    int limit = 60,
    bool includeSaved = true,
  }) async {
    final json = await _send(
      'GET',
      '/api/sessions',
      query: {
        'limit': '$limit',
        // Always explicit: the gateway defaults include_saved to True.
        'include_saved': includeSaved ? 'true' : 'false',
      },
    );
    return SessionsList.fromJson(json);
  }

  Future<SessionInfo> startSession({
    String? cwd,
    String? model,
    String? thinking,
    String? approvalMode,
    String? resumeFrom,
    bool advisor = false,
  }) {
    return _send(
      'POST',
      '/api/sessions',
      body: {
        'cwd': ?cwd,
        'model': ?model,
        'thinking': ?thinking,
        'approvalMode': ?approvalMode,
        'resumeFrom': ?resumeFrom,
        // Sent only when on, like the web client, so older gateways never see it.
        if (advisor) 'advisor': true,
      },
    ).then(SessionInfo.fromJson);
  }

  Future<SessionInfo> sessionInfo(String id) => _send(
    'GET',
    '/api/sessions/${Uri.encodeComponent(id)}',
  ).then(SessionInfo.fromJson);

  /// Stop the child; the transcript stays on disk.
  Future<void> deleteSession(String id) async {
    await _send('DELETE', '/api/sessions/${Uri.encodeComponent(id)}');
  }

  Future<SessionInfo> prompt(
    String id,
    String message, {
    String mode = 'prompt',
    List<Map<String, String>>? images,
  }) {
    return _send(
      'POST',
      '/api/sessions/${Uri.encodeComponent(id)}/prompt',
      body: {
        'message': message,
        'mode': mode,
        if (images != null && images.isNotEmpty) 'images': images,
      },
      timeout: const Duration(seconds: 60),
    ).then(SessionInfo.fromJson);
  }

  Future<void> abort(String id) async {
    await _send('POST', '/api/sessions/${Uri.encodeComponent(id)}/abort');
  }

  /// Ask omp to compact the session context. `instructions` steers what to keep.
  Future<Map<String, dynamic>> compact(String id, {String? instructions}) =>
      _send(
        'POST',
        '/api/sessions/${Uri.encodeComponent(id)}/compact',
        body: {
          if (instructions != null && instructions.isNotEmpty)
            'instructions': instructions,
        },
      );

  Future<Map<String, dynamic>> state(String id) =>
      _send('GET', '/api/sessions/${Uri.encodeComponent(id)}/state');

  Future<Map<String, dynamic>> messages(String id) =>
      _send('GET', '/api/sessions/${Uri.encodeComponent(id)}/messages');

  Future<Map<String, dynamic>> stats(String id) =>
      _send('GET', '/api/sessions/${Uri.encodeComponent(id)}/stats');

  Future<void> setModel(String id, String provider, String modelId) async {
    await _send(
      'POST',
      '/api/sessions/${Uri.encodeComponent(id)}/model',
      body: {'provider': provider, 'modelId': modelId},
    );
  }

  Future<void> setThinking(String id, String level) async {
    await _send(
      'POST',
      '/api/sessions/${Uri.encodeComponent(id)}/thinking',
      body: {'level': level},
    );
  }

  Future<void> setName(String id, String name) async {
    await _send(
      'POST',
      '/api/sessions/${Uri.encodeComponent(id)}/name',
      body: {'name': name},
    );
  }

  Future<Map<String, dynamic>> commands(String id) =>
      _send('GET', '/api/sessions/${Uri.encodeComponent(id)}/commands');

  /// Event backlog since a cursor: `{events, lastSeq, gap}`.
  Future<Map<String, dynamic>> events(String id, {int after = 0}) => _send(
    'GET',
    '/api/sessions/${Uri.encodeComponent(id)}/events',
    query: {'after': '$after'},
  );

  /// Dialogs omp is blocked on: `{pending: [...]}`.
  // ------------------------------------------------ phase-3 gateway routes
  // Raw maps: each feature parses its own shapes (see docs/API.md).

  String _sid(String id) => '/api/sessions/${Uri.encodeComponent(id)}';

  /// Re-run the last failed turn (omp abort_retry). 400 when there is
  /// nothing to retry.
  Future<Map<String, dynamic>> retry(String id) =>
      _send('POST', '${_sid(id)}/retry');

  /// `{entries: [{entryId, role, timestamp}]}`; user rows are fork targets.
  Future<Map<String, dynamic>> entries(String id) =>
      _send('GET', '${_sid(id)}/entries');

  /// Branch at a user entry: `{gwId, forkedFrom, text}`. 409 while busy,
  /// 422 for a non-user/unknown entry.
  Future<Map<String, dynamic>> fork(String id, String entryId) =>
      _send('POST', '${_sid(id)}/fork', body: {'entryId': entryId});

  /// One directory of the session cwd for @-mentions:
  /// `{entries: [{name, path, isDir, size}]}`.
  Future<Map<String, dynamic>> files(String id, {String prefix = ''}) =>
      _send('GET', '${_sid(id)}/files', query: {'prefix': prefix});

  /// `{subagents: [...]}` registry snapshot.
  Future<Map<String, dynamic>> subagents(String id) =>
      _send('GET', '${_sid(id)}/subagents');

  /// One subagent's transcript page: `{messages, nextByte, reset,
  /// sessionFile}`.
  Future<Map<String, dynamic>> subagentMessages(
    String id,
    String subagentId, {
    int? from,
  }) => _send(
    'GET',
    '${_sid(id)}/subagents/${Uri.encodeComponent(subagentId)}/messages',
    query: {if (from != null) 'from': '$from'},
  );

  /// Usage ledger aggregates: `{days, totals, perDay, perModel}`.
  Future<Map<String, dynamic>> ledger({
    int days = 30,
    String? model,
    String? provider,
  }) => _send(
    'GET',
    '/api/ledger',
    query: {'days': '$days', 'model': ?model, 'provider': ?provider},
  );

  /// Per-session rollup: `{days, sessions: [...]}`.
  Future<Map<String, dynamic>> ledgerSessions({int days = 30}) =>
      _send('GET', '/api/ledger/sessions', query: {'days': '$days'});

  Future<List<Map<String, Object?>>> pendingUi(String id) async {
    final json = await _send(
      'GET',
      '/api/sessions/${Uri.encodeComponent(id)}/ui',
    );
    return rawMapList(json['pending']);
  }

  /// Answer one dialog.
  Future<void> answerUi(
    String id,
    String requestId,
    Map<String, Object?> answer,
  ) async {
    await _send(
      'POST',
      '/api/sessions/${Uri.encodeComponent(id)}/ui/${Uri.encodeComponent(requestId)}',
      body: answer,
    );
  }
}
