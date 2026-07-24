import 'package:flutter/material.dart';

import '../services/app_lock.dart';
import '../services/app_state.dart';

/// Envolve o app com um bloqueio biométrico opcional (#2). Quando ativo,
/// exige Face ID/biometria ao abrir e ao voltar do segundo plano.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  final AppLock _lock = AppLock();
  bool _locked = false;
  bool _authenticating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.state.appLockEnabled) {
      _locked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryUnlock());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.state.appLockEnabled) return;
    if (state == AppLifecycleState.paused) {
      if (mounted) setState(() => _locked = true);
    } else if (state == AppLifecycleState.resumed && _locked) {
      _tryUnlock();
    }
  }

  Future<void> _tryUnlock() async {
    if (_authenticating) return;
    _authenticating = true;
    final ok = await _lock.authenticate();
    _authenticating = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_locked)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 64),
                    const SizedBox(height: 16),
                    Text(widget.state.t.appLocked),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _tryUnlock,
                      icon: const Icon(Icons.fingerprint),
                      label: Text(widget.state.t.unlock),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
