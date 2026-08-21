import 'package:flutter/material.dart';
import 'package:liquid_glacier/liquid_glacier.dart';

import 'screens/main_shell.dart';
import 'state/app_state.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FrpApp());
}

class FrpApp extends StatelessWidget {
  const FrpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final accent =
            appAccents[appState.theme.accentIndex % appAccents.length];
        return LiquidGlassTheme(
          data: LiquidGlassThemeData(
            blurSigma: 12,
            opacity: 0.32,
            tintColor: Colors.white,
            borderRadius: BorderRadius.circular(16),
            borderColor: const Color(0x55FFFFFF),
            enableReflection: true,
            enableShadow: true,
          ),
          child: MaterialApp(
            title: 'FRP Android',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(accent),
            darkTheme: AppTheme.dark(accent),
            themeMode: appState.theme.mode,
            home: !appState.initialized
                ? const _InitializationProgress()
                : appState.initializationError != null
                ? _InitializationFailure(message: appState.initializationError!)
                : const MainShell(),
          ),
        );
      },
    );
  }
}

class _InitializationProgress extends StatelessWidget {
  const _InitializationProgress();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _InitializationFailure extends StatelessWidget {
  const _InitializationFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_reset_outlined, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: appState.retryInitialization,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    ),
  );
}
