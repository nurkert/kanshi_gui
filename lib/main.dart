// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pages/home_page.dart';

/*
 * This file is part of kanshi_gui.
 *
 * kanshi_gui is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * kanshi_gui is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with kanshi_gui. If not, see <https://www.gnu.org/licenses/>.
 */
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Reset any leftover keyboard state that might cause assertion errors
  // when a key down event is received while considered already pressed.
  HardwareKeyboard.instance.clearState();
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
