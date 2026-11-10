part of 'session.dart';

typedef ProjectCheckout = ({DesktopSession source, Project project});
typedef DesktopProject = ({String id, ProjectCheckout preferred, List<ProjectCheckout> checkouts});

String? projectRepository(Project project) => canonicalGitRemote(
  project.workspace?['repository'] as String? ?? project.id);

/// A repository and its project subfolder identify a project across machines
/// and worktrees. Folders without a shared identity stay scoped to their owner.
String projectIdentity(DesktopSession source, Project project) {
  final repository = projectRepository(project);
  return repository == null ? source.sidebarId(project.checkoutKey)
    : jsonEncode([repository, project.workspace?['subdirectory'] as String? ?? '']);
}

List<DesktopProject> desktopProjects(Iterable<DesktopSession> sources, {DesktopSession? preferred}) {
  final groups = <String, List<ProjectCheckout>>{};
  for (final source in sources) {
    for (final project in source.projects.where((project) => !project.removing)) {
      (groups[projectIdentity(source, project)] ??= []).add((source: source, project: project));
    }
  }
  int rank(ProjectCheckout checkout) {
    final source = checkout.source, project = checkout.project;
    final availability = !project.available ? 2 : !source.connected ? 1 : 0;
    final selection = identical(source, preferred) && identical(project, preferred?.project) ? 0
      : identical(source, preferred) ? 1 : source.machineAlias == null ? 2 : 3;
    return availability * 16 + selection * 2 + (project.workspace?['worktree'] == true ? 1 : 0);
  }
  return [for (final entry in groups.entries) (
    id: entry.key,
    preferred: entry.value.reduce((a, b) => rank(a) <= rank(b) ? a : b),
    checkouts: List.unmodifiable(entry.value),
  )];
}

String desktopProjectDescription(DesktopProject project) {
  final checkout = project.preferred.project;
  final repository = projectRepository(checkout);
  if (repository == null) return checkout.path;
  final relative = checkout.workspace?['subdirectory'] as String? ?? '';
  return relative.isEmpty ? repository : '$repository · $relative';
}

String desktopProjectSearchText(DesktopProject project) => '${desktopProjectDescription(project)} '
  '${project.checkouts.map((checkout) => '${checkout.project.name} ${checkout.project.path}').join(' ')}';

int desktopProjectActivity(DesktopProject project) => project.checkouts.expand((checkout) => checkout.project.tasks)
  .fold(0, (latest, task) => task.lastActivity > latest ? task.lastActivity : latest);
