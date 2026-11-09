part of 'session.dart';

typedef _DraftContents = ({String text, TextSelection? selection,
  List<ComposerFileReference> files, List<ComposerAttachment> attachments});

_DraftContents _draftContents(DesktopSession session, String id) => (
  text: session.drafts[id] ?? '', selection: session.draftSelections[id],
  files: List.of(session.fileDrafts[id] ?? const []),
  attachments: List.of(session.attachmentDrafts[id] ?? const []),
);

List<ComposerFileReference> _retargetReferences(List<ComposerFileReference> files, String from, String to) => [
  for (final file in files) ComposerFileReference(file.offset,
    file.path == from ? to : file.path.startsWith('$from/') ? '$to/${file.path.substring(from.length + 1)}' : file.path,
    skillName: file.skillName, title: file.title, prompt: file.prompt),
];

extension DraftRouting on DesktopSession {
  /// Prepare and commit the destination before exposing a different machine.
  Future<SessionDraft> receiveDraft(DesktopSession source, SessionDraft original, Project destination,
    {required CancellationToken cancellation}) async {
    final token = cancellation.merge(_lifetime);
    if (original.submission != null || source.submitting) throw StateError('This thread has already started');
    final contents = _draftContents(source, original.id), from = source.project!.path;
    final files = _retargetReferences(contents.files, from, destination.path);
    if (identical(source, this)) {
      final previous = original.checkoutKey;
      original.checkoutKey = destination.checkoutKey;
      fileDrafts[original.id] = files;
      try { await _persistDrafts(); token.throwIfCancelled(); }
      catch (_) {
        original.checkoutKey = previous;
        fileDrafts[original.id] = contents.files;
        await _persistDrafts();
        rethrow;
      }
      return original;
    }
    if (sessionDrafts.any((draft) => draft.id == original.id)) throw StateError('This draft already exists on the target machine');
    final attachments = (await runIsolateEffect(_copyDraftAttachments, {
      'directory': attachmentDirectory,
      'attachments': [for (final attachment in contents.attachments)
        {...attachment.toJson(), 'owned_directory': attachment.ownedDirectory}],
    }, cancellation: token)).map((value) => ComposerAttachment(name: value['name'] as String,
      path: value['path'] as String, image: value['type'] == 'image', ownedDirectory: value['owned_directory'] as String?)).toList();
    final draft = SessionDraft(original.id, destination.checkoutKey, provider: original.provider ?? source.providerId,
      model: original.model ?? source.modelId, reasoning: original.reasoning ?? source.reasoning, tracing: original.tracing);
    sessionDrafts.add(draft);
    openTabIds.add(draft.id);
    drafts[draft.id] = contents.text;
    if (contents.selection != null) draftSelections[draft.id] = contents.selection!;
    fileDrafts[draft.id] = files;
    attachmentDrafts[draft.id] = attachments;
    try {
      await _persistDrafts();
      token.throwIfCancelled();
      return draft;
    } catch (_) { await removeRoutedDraft(draft); rethrow; }
  }

  Future<void> removeRoutedDraft(SessionDraft draft, {bool discardAttachments = true}) async {
    final contents = _draftContents(this, draft.id), index = sessionDrafts.indexOf(draft);
    if (index < 0) return;
    final tabs = List.of(openTabIds), active = _activeDraftId;
    sessionDrafts.remove(draft);
    openTabIds.remove(draft.id);
    drafts.remove(draft.id);
    draftSelections.remove(draft.id);
    fileDrafts.remove(draft.id);
    attachmentDrafts.remove(draft.id);
    if (_activeDraftId == draft.id) _activeDraftId = null;
    try { await _persistDrafts(); }
    catch (_) {
      sessionDrafts.insert(index, draft);
      openTabIds..clear()..addAll(tabs);
      _activeDraftId = active;
      drafts[draft.id] = contents.text;
      if (contents.selection != null) draftSelections[draft.id] = contents.selection!;
      fileDrafts[draft.id] = contents.files;
      attachmentDrafts[draft.id] = contents.attachments;
      rethrow;
    }
    if (discardAttachments) {
      await runIsolateEffect(_discardRoutedAttachments, {'directories': contents.attachments
        .map((attachment) => attachment.ownedDirectory).nonNulls.toSet().toList()}, cancellation: _lifetime);
    }
    _notifyDraftChanges();
  }
}

Future<List<Json>> _copyDraftAttachments(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  final made = <Directory>[], output = <Json>[];
  try {
    for (final raw in params['attachments'] as List) {
      cancellation.throwIfCancelled();
      final attachment = jsonObject(raw);
      if (attachment['owned_directory'] == null) { output.add(attachment); continue; }
      final directory = Directory('${params['directory']}/${newId()}');
      await directory.create(recursive: true);
      made.add(directory);
      final path = '${directory.path}/${File(attachment['path'] as String).uri.pathSegments.last}';
      await File(attachment['path'] as String).copy(path);
      output.add({...attachment, 'path': path, 'owned_directory': directory.path});
    }
    cancellation.throwIfCancelled();
    return output;
  } catch (_) {
    for (final directory in made) { await directory.delete(recursive: true); }
    rethrow;
  }
}

Future<void> _discardRoutedAttachments(Json params, CancellationToken cancellation, void Function(Json) emit) async {
  for (final path in (params['directories'] as List).cast<String>()) {
    cancellation.throwIfCancelled();
    try { await Directory(path).delete(recursive: true); }
    on FileSystemException { /* A disposable draft cache may already be gone. */ }
  }
}
