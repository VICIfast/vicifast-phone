import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/brand.dart';
import '../core/errors.dart';
import '../state/services.dart';
import '../state/session.dart';
import '../ui/adaptive.dart';
import '../ui/tokens.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _company = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _passFocus = FocusNode();
  bool _remember = true;
  bool _busy = false;
  bool _hidePass = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(storeProvider).loadRemembered().then((r) {
      if (r == null || !mounted) return;
      _company.text = r.slug;
      _user.text = r.user;
      _passFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _company.dispose();
    _user.dispose();
    _pass.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  bool get _complete => _company.text.trim().isNotEmpty && _user.text.trim().isNotEmpty && _pass.text.isNotEmpty;

  Future<void> _submit() async {
    if (!_complete || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(sessionProvider.notifier)
          .signIn(slug: _company.text, user: _user.text, pass: _pass.text, remember: _remember);
      if (!mounted) return;
      switch (r) {
        case SignedIn():
          TextInput.finishAutofillContext();
        case NeedsCode():
          await context.push('/signin/code');
        case WebSessionConflict(:final web):
          await _takeOver(web.onCall);
      }
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _takeOver(bool onCall) async {
    final go = await confirm(
      context,
      title: "You're signed in on a computer",
      body: onCall
          ? 'That session is on a call right now. Continuing here ends that call.'
          : 'Continue here to move your session to this phone. The computer will be signed out.',
      action: 'Continue here',
      destructive: onCall,
    );
    if (!go || !mounted) return;
    try {
      final r = await ref.read(sessionProvider.notifier).takeOverWebSession(hangUp: onCall);
      if (r is NeedsCode && mounted) await context.push('/signin/code');
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final notice = ref.watch(signOutNoticeProvider);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xl, Gap.xl, Gap.l),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight - Gap.xl - Gap.l),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(color: c.primary, borderRadius: BorderRadius.circular(12)),
                          child: AppIcon(Ic.phone, color: c.onPrimary, size: 22),
                        ),
                        const SizedBox(width: Gap.m),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(kBrandName, style: context.text.titleMedium),
                            Text('Agent phone', style: context.text.bodySmall),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: Gap.xxl),
                    Text('Sign in', style: context.text.headlineSmall),
                    const SizedBox(height: Gap.l),
                    if (notice != null) ...[_Note(text: notice, tone: c.paused), const SizedBox(height: Gap.l)],
                    TextField(
                      controller: _company,
                      decoration: const InputDecoration(labelText: 'Company code'),
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: Gap.m),
                    TextField(
                      controller: _user,
                      decoration: const InputDecoration(labelText: 'Username'),
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: Gap.m),
                    TextField(
                      controller: _pass,
                      focusNode: _passFocus,
                      obscureText: _hidePass,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          tooltip: _hidePass ? 'Show password' : 'Hide password',
                          onPressed: () => setState(() => _hidePass = !_hidePass),
                          icon: AppIcon(_hidePass ? Ic.eye : Ic.eyeOff, color: c.ink2),
                        ),
                      ),
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.go,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: Gap.s),
                    MergeSemantics(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _remember = !_remember),
                        child: Row(
                          children: [
                            Expanded(child: Text('Remember company and username', style: context.text.bodyMedium)),
                            AppSwitch(value: _remember, onChanged: (v) => setState(() => _remember = v)),
                          ],
                        ),
                      ),
                    ),
                    if (_error != null) ...[const SizedBox(height: Gap.m), _Note(text: _error!, tone: c.problem)],
                    const SizedBox(height: Gap.xl),
                    AppButton(label: 'Sign in', onPressed: _complete ? _submit : null, busy: _busy),
                    const SizedBox(height: Gap.m),
                    Text(
                      'Your company code is in the welcome email from your supervisor.',
                      textAlign: TextAlign.center,
                      style: context.text.bodySmall?.copyWith(color: c.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CodeScreen extends ConsumerStatefulWidget {
  const CodeScreen({super.key});

  @override
  ConsumerState<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends ConsumerState<CodeScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _code.text.replaceAll(RegExp(r'\D'), '');
    if (code.length != 6 || _busy) return;
    final session = ref.read(sessionProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pending = ref.read(pendingSignInProvider);
      if (pending == null) {
        if (mounted) context.pop();
        return;
      }
      final r = await session.signIn(
        slug: pending.slug,
        user: pending.user,
        pass: pending.pass,
        code: code,
        remember: pending.remember,
      );
      if (r is NeedsCode && mounted) setState(() => _error = const AppError(AppErrorCode.codeRejected).message);
    } on AppError catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
        _code.clear();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppHeader(title: 'Your code', backLabel: 'Sign in', onBack: () => context.pop(), large: true),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Open your authenticator app and enter the 6\u2011digit code for $kBrandName.',
                      style: context.text.bodyLarge,
                    ),
                    const SizedBox(height: Gap.xl),
                    Semantics(
                      label: '6-digit code',
                      child: TextField(
                        controller: _code,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 30,
                          letterSpacing: 14,
                          fontWeight: FontWeight.w500,
                          color: c.ink,
                          fontFeatures: tabular,
                        ),
                        decoration: InputDecoration(
                          hint: ExcludeSemantics(
                            child: Text(
                              '······',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 30, letterSpacing: 14, color: c.muted),
                            ),
                          ),
                        ),
                        onChanged: (v) {
                          setState(() {});
                          if (v.length == 6) _verify();
                        },
                      ),
                    ),
                    const SizedBox(height: Gap.s),
                    Text('You can paste the whole code.', style: context.text.bodySmall?.copyWith(color: c.muted)),
                    if (_error != null) ...[const SizedBox(height: Gap.m), _Note(text: _error!, tone: c.problem)],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
              child: AppButton(label: 'Verify', onPressed: _code.text.length == 6 ? _verify : null, busy: _busy),
            ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.tone});

  final String text;
  final StateTone tone;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.m + 2, vertical: Gap.m),
      decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(context.cardRadius)),
      child: Text(text, style: context.text.bodyMedium?.copyWith(color: context.colors.ink)),
    ),
  );
}
