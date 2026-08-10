/// Web stand-in for the loopback asset server.
///
/// A browser tab has no sockets to bind and no WebView to host, so the body
/// renderer simply doesn't exist there. Failing loudly here is deliberate: the
/// caller already treats a failed start as "show the list instead", which is
/// the right answer on web too.
class BodyServer {
  BodyServer._();

  Uri get origin => throw UnsupportedError('No body renderer on web.');

  static Future<BodyServer> instance() =>
      Future.error(UnsupportedError('No body renderer on web.'));
}
