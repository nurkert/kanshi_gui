// lib/main.dart

import 'package:flutter/material.dart';
import 'pages/home_page.dart';

void main() {
  runApp(const KanshiApp());
}

class KanshiApp extends StatelessWidget {
  const KanshiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kanshi GUI',
      theme: ThemeData.dark(),
      home: const HomePage(),
    );
  }
}