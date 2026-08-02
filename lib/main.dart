import 'package:flutter/material.dart';

import 'screens/home_shell.dart';

void main() {
  runApp(const SonyTransferApp());
}

class SonyTransferApp extends StatelessWidget {
  const SonyTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sony Transfer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF5A623),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}
