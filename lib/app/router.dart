import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';
import '../domain/presence.dart';
import '../features/call.dart';
import '../features/calls.dart';
import '../features/home.dart';
import '../features/me.dart';
import '../features/setup.dart';
import '../features/shell.dart';
import '../features/shift.dart';
import '../features/signin.dart';
import '../features/wrapup.dart';
import '../state/agent.dart';
import '../state/session.dart';
import '../state/shift.dart';

/// Re-runs the router's redirect whenever something that decides the screen changes.
class _Refresh extends ChangeNotifier {
  _Refresh(Ref ref) {
    ref.listen(sessionProvider, (_, _) => notifyListeners());
    ref.listen(setupSeenProvider, (_, _) => notifyListeners());
    ref.listen(setupStatusProvider, (_, _) => notifyListeners());
    ref.listen<PresenceKind>(agentProvider.select((p) => p.kind), (_, _) => notifyListeners());
  }
}

const _callRoutes = {'/incoming', '/call', '/wrapup'};

/// The single source of truth for which screen the agent may see.
String? decideRoute(Ref ref, String loc) {
  final session = ref.read(sessionProvider);
  if (!session.hasValue) return loc == '/boot' ? null : '/boot';
  final s = session.value;
  if (s == null) return loc.startsWith('/signin') ? null : '/signin';

  // A call outranks everything below: a cold start from the ring must show it.
  final callRoute = callRouteFor(ref.read(agentProvider).kind);
  if (callRoute != null) return loc == callRoute ? null : callRoute;

  final setup = ref.read(setupStatusProvider).value;
  final seen = ref.read(setupSeenProvider);
  if (!seen && setup != null && !setup.ready) return loc == '/setup' ? null : '/setup';

  if (!s.hasShift) return loc == '/shift' || loc == '/setup' ? null : '/shift';

  if (_callRoutes.contains(loc) || loc.startsWith('/signin') || loc == '/boot') return '/home';
  return null;
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _Refresh(ref);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/boot',
    refreshListenable: refresh,
    redirect: (context, state) => decideRoute(ref, state.matchedLocation),
    routes: [
      GoRoute(path: '/boot', builder: (_, _) => const _Boot()),
      GoRoute(
        path: '/signin',
        builder: (_, _) => const SignInScreen(),
        routes: [GoRoute(path: 'code', builder: (_, _) => const CodeScreen())],
      ),
      GoRoute(path: '/setup', builder: (_, _) => const SetupScreen()),
      GoRoute(path: '/shift', builder: (_, _) => const ShiftScreen()),
      GoRoute(
        path: '/incoming',
        builder: (_, _) => const StayInApp(child: IncomingScreen()),
      ),
      GoRoute(
        path: '/call',
        builder: (_, _) => const StayInApp(child: CallScreen()),
      ),
      GoRoute(
        path: '/wrapup',
        builder: (_, _) => const StayInApp(child: WrapUpScreen()),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => TabShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/calls',
                builder: (_, _) => const CallsScreen(),
                routes: [
                  GoRoute(
                    path: 'detail',
                    builder: (_, state) => state.extra is CallRecord
                        ? CallDetailScreen(record: state.extra! as CallRecord)
                        : const CallsScreen(),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/me', builder: (_, _) => const MeScreen())],
          ),
        ],
      ),
    ],
  );
});

class _Boot extends StatelessWidget {
  const _Boot();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator.adaptive()));
}
