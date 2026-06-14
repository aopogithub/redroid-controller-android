import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/connection_screen.dart';
import 'services/scrcpy_connection.dart';

void main() {
  runApp(const RedroidControllerApp());
}

class RedroidControllerApp extends StatelessWidget {
  const RedroidControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ScrcpyConnection(),
      child: MaterialApp(
        title: 'RedroidController',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.red,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.red,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const ConnectionScreen(),
      ),
    );
  }
}
