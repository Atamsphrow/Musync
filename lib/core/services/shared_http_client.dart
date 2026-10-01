/// One HTTP client shared by every network caller in the app.
///
/// A single client for lyrics sources, AI filename reads, and anything else
/// that talks HTTP. Constructing a client per source (and per provider
/// rebuild) leaked sockets — `http.Client` is meant to be long-lived and
/// shared, and it is closed when the provider scope goes away.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// A single client for lyrics sources, AI filename reads, and anything else
/// that talks HTTP. Constructing a client per source (and per provider
/// rebuild) leaked sockets — `http.Client` is meant to be long-lived and
/// shared, and it is closed when the provider scope goes away.
final sharedHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});
