import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/core/logging/app_logger.dart';

/// A lightweight HTTP server that serves a JSON payload over the local network,
/// so another device on the same Wi-Fi / hotspot can fetch it via a plain URL.
///
/// The server binds to the loopback + LAN IPs on a random port and exposes a
/// single GET endpoint at `/` that returns the configured JSON body. It is
/// designed for short-lived transfers — call [stop] once the receiver has
/// confirmed the download.
class LanTransferService {
  HttpServer? _server;
  final String _jsonPayload;
  final String _fileName;

  LanTransferService._(this._jsonPayload, this._fileName);

  /// Starts a new LAN share session serving [jsonPayload] under [fileName].
  /// Returns the bound [LanShareInfo] or throws if the server cannot start.
  static Future<LanShareInfo> start({
    required String jsonPayload,
    String fileName = 'export.json',
  }) async {
    final service = LanTransferService._(jsonPayload, fileName);
    await service._start();
    return await service._buildInfo();
  }

  Future<void> _start() async {
    // Bind on 0.0.0.0 so both loopback and LAN interfaces can reach us.
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.defaultResponseHeaders.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    _server!.listen((request) {
      unawaited(_handleRequest(request));
    });
    AppLogger.info(
      'LAN transfer server bound on port ${_server!.port}',
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method == 'GET' || request.method == 'HEAD') {
        final bytes = utf8.encode(_jsonPayload);
        request.response.headers
          ..contentLength = bytes.length
          ..set(HttpHeaders.contentDisposition, 'attachment; filename="$_fileName"');
        if (request.method == 'GET') {
          request.response.add(bytes);
        }
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
      }
    } catch (e) {
      AppLogger.warn('LAN transfer request error: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      AppLogger.info('LAN transfer server stopped');
    }
  }

  Future<LanShareInfo> _buildInfo() async {
    final port = _server!.port;
    final lanIp = await _findLanIp();
    final url = lanIp != null
        ? 'http://$lanIp:$port/$_fileName'
        : 'http://127.0.0.1:$port/$_fileName';
    return LanShareInfo(
      url: url,
      port: port,
      lanIp: lanIp,
      fileName: _fileName,
      service: this,
    );
  }

  /// Finds the first non-loopback, non-link-local IPv4 address available.
  /// Falls back to null if no suitable address is found (e.g. no network).
  Future<String?> _findLanIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type.name == 'IPv4' &&
              !addr.isLoopback &&
              !addr.isLinkLocal) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      AppLogger.warn('Failed to enumerate network interfaces: $e');
    }
    return null;
  }
}

/// Metadata about an active LAN share session.
class LanShareInfo {
  final String url;
  final int port;
  final String? lanIp;
  final String fileName;
  final LanTransferService service;

  const LanShareInfo({
    required this.url,
    required this.port,
    required this.lanIp,
    required this.fileName,
    required this.service,
  });
}

/// High-level check: returns true when the device has a non-loopback network
/// connection (Wi-Fi, mobile, or a hotspot). Best-effort — a missing network
/// on short timeout returns false rather than throwing.
Future<bool> hasLanConnection() async {
  try {
    final connectivity = Connectivity();
    final results = await connectivity.checkConnectivity();
    // connectivity_plus v7+ returns a List<ConnectivityResult>.
    for (final result in results) {
      if (result != ConnectivityResult.none) {
        return true;
      }
    }
  } catch (_) {}
  return false;
}

/// Downloads JSON text from an HTTP URL. Used by the receiving side in a
/// LAN transfer. Throws on failure or on timeout (default 15s).
Future<String> fetchJsonFromUrl(String url, {Duration timeout = const Duration(seconds: 15)}) async {
  final client = HttpClient();
  try {
    final uri = Uri.parse(url);
    final request = await client.getUrl(uri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    final buffer = StringBuffer();
    await for (final chunk in response.transform(utf8.decoder)) {
      buffer.write(chunk);
    }
    if (response.statusCode != 200) {
      throw HttpException(
        'HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    // Validate that the response is JSON before handing it back.
    jsonDecode(buffer.toString());
    return buffer.toString();
  } on TimeoutException {
    throw ObtainiumError(tr('lanImportNoServer'));
  } finally {
    client.close();
  }
}
