import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/device_detail_screen.dart';
import 'screens/device_list_screen.dart';

void main() {
  // Catch all errors in the Flutter framework
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };

  // Catch all errors outside Flutter framework
  runZonedGuarded(
    () {
      runApp(const MyApp());
    },
    (error, stack) {
      // Log error but don't crash
      debugPrint('Uncaught error: $error');
      debugPrint('Stack trace: $stack');
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp.router(
        title: 'BACnet Demo',
        theme: ThemeData.dark().copyWith(
          primaryColor: Colors.teal,
          scaffoldBackgroundColor: const Color(0xFF1E1E1E),
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
        ),
        routerConfig: _router,
      ),
    );
  }
}

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const DeviceListScreen()),
    GoRoute(
      path: '/device/:id',
      builder: (context, state) {
        final deviceId = int.parse(state.pathParameters['id']!);
        return DeviceDetailScreen(deviceId: deviceId);
      },
    ),
  ],
);
