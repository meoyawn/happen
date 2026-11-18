part of '../server.dart';

enum _DictationPhase { waiting, opening, recording, finishing }

final _dictationOrigin = Uri.parse('https://chatgpt.com');

String _dictationScope(Json authorization) {
  requiredString(authorization, 'account_id');
  return openAICredentialScope(_dictationOrigin, authorization) ??
    (throw StateError('Sign in to ChatGPT on this computer to use dictation'));
}

extension _WebDictation on AgentServer {
  Future<Json> _dictationAuthorization({bool refresh = false, required CancellationToken cancellation}) async =>
    jsonObject(await _callNetwork('auth.desktop', {'refresh': refresh}, cancellation: cancellation,
      timeout: const Duration(seconds: 12)));

  Future<void> _acceptWebDictation(HttpRequest request) async {
    if (_webDictations.length >= 8) {
      request.response.statusCode = 503;
      await request.response.close();
      return;
    }
    final cancellation = CancellationToken();
    _webDictations.add(cancellation);
    final operation = _serveWebDictation(request, cancellation);
    _requests.add(operation);
    try { await operation; }
    finally { _requests.remove(operation); _webDictations.remove(cancellation); }
  }

  Future<void> _serveWebDictation(HttpRequest request, CancellationToken owner) async {
    final deadline = TimeoutCancellationToken(const Duration(minutes: 12));
    final cancellation = owner.merge(_lifetime).merge(deadline);
    WebSocket? connection;
    StreamSubscription<dynamic>? input;
    TranscriptionStream? live;
    HttpClient? http;
    var phase = _DictationPhase.waiting;
    final start = Completer<({bool live, String scope})>();
    final finish = Completer<void>();
    final pcm = BytesBuilder(copy: false);
    var audioBytes = 0;

    void send(Json message) {
      if (!cancellation.isCancelled && connection?.readyState == WebSocket.open) connection!.add(jsonEncode(message));
    }
    void fail(String message) {
      send({'type': 'error', 'message': message});
      owner.cancel();
    }

    try {
      connection = await WebSocketTransformer.upgrade(request,
        compression: CompressionOptions.compressionOff, maxPayloadLength: dictationMaxFrameBytes);
      input = connection.listen((raw) {
        if (cancellation.isCancelled) return;
        try {
          switch ((phase, raw)) {
            case (_DictationPhase.waiting, final String frame) when frame.length <= 1024:
              final message = jsonObject(jsonDecode(frame));
              if (message case {'type': 'start', 'live': final bool streaming, 'account_scope': final String scope}
                when scope.length == 64) {
                phase = _DictationPhase.opening;
                start.complete((live: streaming, scope: scope));
              } else { fail('Start dictation again'); }
            case (_DictationPhase.recording, final List<int> bytes) when bytes.isNotEmpty && bytes.length.isEven:
              audioBytes += bytes.length;
              if (audioBytes > dictationMaxAudioBytes) { fail('The recording is too long'); return; }
              if (live case final stream?) { stream.append(Uint8List.fromList(bytes)); }
              else { pcm.add(bytes); }
            case (_DictationPhase.recording, 'finish'):
              phase = _DictationPhase.finishing;
              finish.complete();
            default:
              fail('Start dictation again');
          }
        } catch (_) { fail('Unable to transcribe audio'); }
      }, onError: (Object _) => owner.cancel(), onDone: owner.cancel);

      final selection = await start.future.timeout(const Duration(seconds: 10)).asCancellable(cancellation);
      Future<Json> credentials({bool refresh = false, required CancellationToken cancellation}) async {
        final auth = await _dictationAuthorization(refresh: refresh, cancellation: cancellation);
        if (_dictationScope(auth) != selection.scope) {
          throw StateError('The signed-in workspace changed. Start dictation again.');
        }
        return auth;
      }

      final auth = await credentials(cancellation: cancellation);
      if (selection.live) {
        final stream = live = TranscriptionStream(
          onTranscript: (text) => send({'type': 'transcript', 'text': text}),
          onError: () => fail('Unable to transcribe audio'),
        );
        await stream.connect(auth, cancellation: cancellation);
      }
      cancellation.throwIfCancelled();
      phase = _DictationPhase.recording;
      send({'type': 'ready'});
      await finish.future.asCancellable(cancellation);
      if (audioBytes == 0) throw StateError("Didn't quite catch that. Please try again");

      final String text;
      if (live case final stream?) {
        await credentials(cancellation: cancellation);
        text = await stream.finish();
      } else {
        final client = http = HttpClient()..connectionTimeout = const Duration(seconds: 30);
        final transcription = TranscriptionClient(http: client, credentials: credentials);
        text = await transcription.transcribe(dictationWav(pcm.takeBytes()), accountId: requiredString(auth, 'account_id'),
          cancellation: cancellation);
      }
      send({'type': 'finished', 'text': text});
    } on CancelledException { /* Disconnect, shutdown, or account change owns cancellation. */ }
    catch (failure) { send({'type': 'error', 'message': dictationErrorMessage(failure) ?? 'Unable to transcribe audio'}); }
    finally {
      owner.cancel();
      deadline.cancel();
      live?.close();
      http?.close(force: true);
      try { await connection?.close(); }
      catch (_) { /* The peer may already have disconnected. */ }
      await input?.cancel();
    }
  }
}
