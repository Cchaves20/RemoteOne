import 'package:flutter/material.dart';

import '../models/device.dart';
import '../models/remote_app.dart';
import '../services/app_state.dart';
import '../widgets/pulse.dart';

/// Aplicativos do computador (Etapa 8): abrir os instalados e encerrar os que
/// estão abertos. A lista é consultada no computador na hora.
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key, required this.state, required this.device});

  final AppState state;
  final Device device;

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(_onTabChanged);
  final _search = TextEditingController();

  // Uma lista por aba: instalados (0) e abertos (1).
  final Map<int, List<RemoteApp>> _apps = {};
  final Map<int, String?> _errors = {};
  final Set<int> _loading = {};

  @override
  void initState() {
    super.initState();
    _load(0);
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    setState(() {}); // atualiza o filtro/estado vazio
    if (!_apps.containsKey(_tabs.index)) _load(_tabs.index);
  }

  Future<void> _load(int tab) async {
    setState(() {
      _loading.add(tab);
      _errors[tab] = null;
    });
    try {
      final apps = await widget.state.listApps(
        widget.device,
        kind: tab == 0 ? 'installed' : 'running',
      );
      if (mounted) setState(() => _apps[tab] = apps);
    } catch (e) {
      if (mounted) setState(() => _errors[tab] = e.toString());
    } finally {
      if (mounted) setState(() => _loading.remove(tab));
    }
  }

  Future<void> _launch(RemoteApp app) async {
    final t = widget.state.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.state.launchApp(widget.device, app.id);
      messenger.showSnackBar(SnackBar(content: Text(t.appOpening(app.name))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _close(RemoteApp app) async {
    final t = widget.state.t;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.appClose),
        content: Text(t.appCloseConfirm(app.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.appClose),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.state.closeApp(widget.device, app.id);
      messenger.showSnackBar(SnackBar(content: Text(t.appClosed(app.name))));
      _load(1); // a lista de abertos mudou
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  List<RemoteApp> _filtered(int tab) {
    final all = _apps[tab] ?? const <RemoteApp>[];
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((a) => a.name.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.state.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.apps),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(_tabs.index),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: t.appsInstalled),
            Tab(text: t.appsRunning),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: t.appsSearch,
                prefixIcon: const Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [_tabBody(0), _tabBody(1)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabBody(int tab) {
    final t = widget.state.t;
    if (_loading.contains(tab)) return const _AppsSkeleton();

    final error = _errors[tab];
    if (error != null) {
      return _centered(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 56, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => _load(tab), child: Text(t.retry)),
        ],
      ));
    }

    final apps = _filtered(tab);
    if (apps.isEmpty) {
      return _centered(Text(
        tab == 0 ? t.appsEmptyInstalled : t.appsEmptyRunning,
        textAlign: TextAlign.center,
      ));
    }

    return RefreshIndicator(
      onRefresh: () => _load(tab),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        itemCount: apps.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                t.appsHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            );
          }
          final app = apps[i - 1];
          return Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              leading: Icon(tab == 0 ? Icons.apps : Icons.play_circle_outline),
              title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: tab == 0
                  ? const Icon(Icons.open_in_new, size: 20)
                  : IconButton(
                      tooltip: t.appClose,
                      icon: Icon(Icons.close,
                          color: Theme.of(context).colorScheme.error),
                      onPressed: () => _close(app),
                    ),
              onTap: tab == 0 ? () => _launch(app) : null,
            ),
          );
        },
      ),
    );
  }

  Widget _centered(Widget child) => Center(
        child: Padding(padding: const EdgeInsets.all(32), child: child),
      );
}

/// Placeholder animado enquanto o computador responde com a lista.
class _AppsSkeleton extends StatelessWidget {
  const _AppsSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Pulse(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        children: List.generate(
          7,
          (_) => Card(
            elevation: 0,
            color: scheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  SkeletonBox(width: 24, height: 24, radius: 6),
                  SizedBox(width: 14),
                  SkeletonBox(width: 160, height: 14),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
