import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

typedef ImageSender = Future<Json> Function(Json body, {required bool edit, required String turnId, required CancellationToken cancellation});

/// OpenAI Images API / Codex image_gen.imagegen contract. File work is bounded
/// and caller-owned; no model report is accepted as proof that an image exists.
Future<Json> generateImage(ModelRequest request, Json arguments, {
  required ImageSender send,
  required String outputRoot,
  required String callId,
  required String turnId,
  required CancellationToken cancellation,
}) async {
  cancellation.throwIfCancelled();
  const allowed = {'prompt', 'transparent_background', 'referenced_image_paths', 'num_last_images_to_include'};
  if (arguments.keys.any((key) => !allowed.contains(key))) throw const FormatException('Unknown image generation argument');
  final prompt = arguments['prompt'];
  if (prompt is! String) throw const FormatException('prompt must be a string');
  final transparent = arguments['transparent_background'] ?? false;
  if (transparent is! bool) throw const FormatException('transparent_background must be a boolean');
  final paths = arguments['referenced_image_paths'];
  if (paths != null && (paths is! List || paths.length > 5 || paths.any((path) => path is! String || File(path).absolute.path != path))) {
    throw const FormatException('referenced_image_paths must contain at most 5 absolute paths');
  }
  final count = arguments['num_last_images_to_include'];
  if (count != null && (count is! int || count < 1 || count > 5)) throw const FormatException('num_last_images_to_include must be between 1 and 5');
  if (paths is List && paths.isNotEmpty && count != null) throw const FormatException('provide only one of referenced_image_paths or num_last_images_to_include');
  final images = <String>[];
  if (paths is List && paths.isNotEmpty) {
    final prepared = await prepareInputAttachments([for (final path in paths) {
      'type': 'image', 'name': 'Referenced image', 'path': path, 'detail': 'original',
    }], cancellation: cancellation);
    images.addAll(prepared.map(attachmentDataUrl));
  } else if (count is int) {
    final recent = <String>[];
    for (final item in request.input) {
      for (final part in item.content) {
        if (part['type'] == 'image') recent.add(attachmentDataUrl(part));
        if (part['type'] == 'tool_result') {
          // Native output retains source order; UI shadow attachments must not
          // count the same generated image a second time.
          final gpt = jsonObject(jsonObject(part['native'] ?? {})['gpt'] ?? {});
          if (gpt['content_items'] == true) {
            final content = jsonDecode(part['output'] as String) as List;
            recent.addAll(content.where((value) => value['type'] == 'input_image').map((value) => value['image_url'] as String));
          }
          if (gpt['inline_images'] != true) recent.addAll((part['images'] as List? ?? []).map((image) => attachmentDataUrl(jsonObject(image))));
        }
      }
    }
    if (recent.length < count) throw FormatException('requested the last $count conversation images, but only ${recent.length} were available');
    images.addAll(recent.skip(recent.length - count));
  }
  final response = await send({
    if (images.isNotEmpty) 'images': [for (final image in images) {'image_url': image}],
    'prompt': prompt, 'background': transparent ? 'transparent' : 'opaque',
    'model': 'gpt-image-2', 'quality': 'auto', 'size': 'auto',
  }, edit: images.isNotEmpty, turnId: turnId, cancellation: cancellation);
  cancellation.throwIfCancelled();
  final data = response['data'];
  if (data is! List || data.isEmpty || data.first is! Map || data.first['b64_json'] is! String) {
    throw const ModelFailure('image_generation_response', 'image generation returned no image data');
  }
  final encoded = data.first['b64_json'] as String;
  if (encoded.length > ((32 * 1024 * 1024 + 2) ~/ 3) * 4) throw const ModelFailure('image_generation_size', 'Generated image exceeds 32 MiB');
  String safe(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final folder = Directory('$outputRoot/generated_images/${safe(request.taskId)}');
  final target = File('${folder.path}/${safe(callId)}.png');
  final temporary = File('${target.path}.partial-${newId()}');
  String? saved;
  try { saved = await CancellableIsolate.run(() {
    final bytes = base64Decode(encoded.trim());
    if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) throw const FormatException('Invalid generated image bytes');
    try {
      folder.createSync(recursive: true);
      temporary.writeAsBytesSync(bytes, flush: true);
      temporary.renameSync(target.path);
      return target.path;
    } on FileSystemException { return null; }
  }, cancellation); }
  finally { try { await temporary.delete(); } on FileSystemException { /* Never publish an interrupted partial image. */ } }
  final hint = saved == null ? null : 'Generated images are saved to ${File(saved).parent.path} as $saved by default.\n'
    'If you need to use a generated image at another path, copy it and leave the original in place unless the user explicitly asks you to delete it.\n'
    'The generated image is already displayed to the user. There is no need to render it in the final response as a Markdown image or file link.';
  return {'image_url': 'data:image/png;base64,$encoded', if (hint != null && utf8.encode(hint).length <= 1024) 'output_hint': hint};
}

const imageGenerationCatalog = <String, dynamic>{
  'name': 'imagegen', 'tool_name': 'imagegen', 'namespace': 'image_gen',
  'namespace_description': 'Tools in the image_gen namespace.',
  'description': _description,
  // Match Codex's serialized JsonSchema subset for this reserved tool. Defaults
  // and numeric/length bounds stay enforced by generateImage, not on the wire.
  'parameters': {'type': 'object', 'properties': {
    'prompt': {'type': 'string'},
    'transparent_background': {'type': 'boolean', 'description': 'Whether the output should have a transparent background. Defaults to false.'},
    'referenced_image_paths': {'type': ['array', 'null'], 'items': {'type': 'string'}},
    'num_last_images_to_include': {'type': ['integer', 'null']},
  }, 'required': ['prompt'], 'additionalProperties': false},
  'output_schema': {'type': 'object', 'properties': {
    'image_url': {'type': 'string'}, 'output_hint': {'type': 'string'},
  }, 'required': ['image_url'], 'additionalProperties': false},
};

const _description = '''The `image_gen.imagegen` tool enables image generation from descriptions and editing of existing images based on specific instructions. Use it when:

- The user requests an image based on a scene description, such as a diagram, portrait, comic, meme, or any other visual.
- The user wants to modify an attached or previously generated image with specific changes, including adding or removing elements, altering colors, improving quality/resolution, or transforming the style (e.g., cartoon, oil painting).

Guidelines:
- imagegen needs a few minutes to finish. In code-mode, use the first-line @exec directive to give the initial call 120 seconds and the same yield for any waits that follow. Once it finishes, return the image with generatedImage(result).
- Avoid printing the full result or its base64 image data with `text()` or `notify()`; print only small metadata when needed.
- Set `transparent_background` to true when the request calls for a transparent background, including background removal or a cutout; set it to false otherwise. For edits, preserve existing transparency unless the user asks to change it.
- Omit both `referenced_image_paths` and `num_last_images_to_include` when generating a brand new image.
- For edits, use `referenced_image_paths` when every target image has a local file path.
- If you have not seen a local image yet, use `view_image` to inspect it before editing.
- Use `num_last_images_to_include` only when at least one target image has no local file path.
- Set `num_last_images_to_include` to the smallest number of recent conversation images that includes every target image, up to 5.
- Never provide both `referenced_image_paths` and `num_last_images_to_include`.
- If neither mechanism can include every target image, ask the user to attach the missing images again.
- Directly generate the image without reconfirmation or clarification unless required images must be attached again.
- Always use this tool for image editing unless the user explicitly requests otherwise. Do not use the `python` tool for image editing unless specifically instructed.
''';
