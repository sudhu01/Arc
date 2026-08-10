// The body renderer's asset server, picked per platform at compile time.
//
// The real implementation needs `dart:io` to open a socket, which does not
// exist on web — and importing it unconditionally would break the web build
// outright, not just this screen. The stub keeps web compiling; [BodyView]
// catches the error it throws and falls the Exercises screen back to the list.
export 'body_server_stub.dart' if (dart.library.io) 'body_server_io.dart';
