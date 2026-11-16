import '../protocol.dart';

/// Codex's client response blocks expressed as model input content. The server
/// validates the envelope before it reaches providers or durable tool records.
List<Json> clientToolContent(Json result) => [
  for (final raw in result['contentItems'] as List) switch (jsonObject(raw)) {
    {'type': 'inputText', 'text': final String text} => {'type': 'input_text', 'text': text},
    {'type': 'inputImage', 'imageUrl': final String url} => {'type': 'input_image', 'image_url': url, 'detail': 'high'},
    {'type': 'inputAudio', 'audioUrl': final String url} => {'type': 'input_audio', 'audio_url': url},
    _ => throw const FormatException('Invalid client tool content item'),
  },
];
