import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/home_page.dart';
import 'providers/profile_provider.dart';
import 'utils/logger.dart';

/// Root widget of the application.
class KanshiApp extends StatelessWidget {
  const KanshiApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProfileProvider()..init()),
      ],
      child: MaterialApp(
        title: 'Kanshi GUI',
        theme: ThemeData.dark(),
        home: const HomePage(),
        navigatorObservers: [LoggingObserver()],
      ),
    );
  }
}
