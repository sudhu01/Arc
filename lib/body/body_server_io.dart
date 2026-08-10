import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

/// Serves the body renderer's assets to the WebView over loopback HTTP.
///
/// The page could in principle be loaded straight off the filesystem, but
/// WKWebView refuses cross-origin reads from `file://`, which kills ES module
/// imports — and the renderer is a module that imports three.js. An `http://`
/// origin makes modules, `fetch` and workers all behave the way they do
/// anywhere else.
///
/// Nothing here reaches the network: every byte comes out of the app bundle, so
/// the body renders the same in a basement gym as on wifi. No user data is ever
/// served — workout state crosses on the JavaScript channel, not over HTTP.
class BodyServer {
  BodyServer._(this._server, this.origin);

  final HttpServer _server;

  /// Base URL including the per-launch path token, e.g.
  /// `http://127.0.0.1:53412/a91f…`. Everything is served under it.
  final Uri origin;

  static Future<BodyServer>? _pending;

  /// Starts the server, or returns the one already running. Idempotent and
  /// safe to call from every rebuild — the Exercises tab lives inside an
  /// `IndexedStack` and will ask more than once.
  static Future<BodyServer> instance() => _pending ??= _start();

  static Future<BodyServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;

    // Any app on the device can reach a loopback port. Nothing served here is
    // sensitive, but an unguessable prefix keeps stray traffic from other
    // processes out of the renderer's URL space.
    final rand = Random.secure();
    final token = List.generate(16, (_) => rand.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    // The trailing slash matters. Without it the browser treats `$token` as a
    // filename, so `body.js` resolves to `/body.js` instead of
    // `/$token/body.js` and every relative import 404s.
    final origin = Uri.parse('http://127.0.0.1:${server.port}/$token/');
    final instance = BodyServer._(server, origin);
    unawaited(instance._serve(token));
    return instance;
  }

  Future<void> _serve(String token) async {
    await for (final req in _server) {
      unawaited(_handle(req, token));
    }
  }

  Future<void> _handle(HttpRequest req, String token) async {
    try {
      // A trailing slash leaves an empty final segment in Dart's parse.
      final segments =
          req.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (req.method != 'GET' ||
          segments.isEmpty ||
          segments.first != token ||
          segments.length > 4) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final file = segments.length == 1
          ? 'index.html'
          : segments.skip(1).join('/');
      if (!_allowed.containsKey(file)) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final bytes = await rootBundle.load('assets/body/$file');
      req.response
        ..headers.contentType = _allowed[file]!
        // The bundle is the only source; a cached copy can only go stale
        // against a fresh build of the app.
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..headers.set('X-Content-Type-Options', 'nosniff')
        ..add(bytes.buffer.asUint8List(
            bytes.offsetInBytes, bytes.lengthInBytes));
      await req.response.close();
    } catch (_) {
      // A dropped connection while the WebView tears down is routine; a broken
      // response here surfaces as the load timeout, which already falls back.
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// Explicit allow-list rather than "anything under assets/body" — the server
  /// should never become a way to read the rest of the bundle. Paths are
  /// matched whole, so no amount of `..` in a request can walk out of it.
  static final Map<String, ContentType> _allowed = {
    'index.html': ContentType.html,
    'body.js': _js,
    'three.module.min.js': _js,
    'body.bin': ContentType.binary,
    for (final name in const [
      'EffectComposer', 'Pass', 'RenderPass', 'ShaderPass', 'MaskPass',
      'UnrealBloomPass', 'OutputPass',
    ])
      'addons/postprocessing/$name.js': _js,
    for (final name in const [
      'CopyShader', 'LuminosityHighPassShader', 'OutputShader',
    ])
      'addons/shaders/$name.js': _js,
  };

  static final _js = ContentType('text', 'javascript', charset: 'utf-8');
}
