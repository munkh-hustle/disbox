import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/setup_screen.dart';
import 'screens/file_browser_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Hive for local storage (if using Hive)
  // await Hive.initFlutter();
  // await Hive.openBox('disbox_cache');
  
  runApp(const DisboxApp());
}

/// Main Disbox application widget.
class DisboxApp extends StatelessWidget {
  const DisboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Disbox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
      themeMode: ThemeMode.system, // Follow system theme
      home: const AppStartup(),
    );
  }
}

/// Handles app startup and determines which screen to show.
class AppStartup extends StatefulWidget {
  const AppStartup({super.key});

  @override
  State<AppStartup> createState() => _AppStartupState();
}

class _AppStartupState extends State<AppStartup> {
  bool _isLoading = true;
  bool _hasWebhook = false;

  @override
  void initState() {
    super.initState();
    _checkSetup();
  }

  /// Check if webhook URL is configured
  Future<void> _checkSetup() async {
    try {
      print('[AppStartup] Checking setup...');
      final prefs = await SharedPreferences.getInstance();
      final webhookUrl = prefs.getString('webhook_url');
      final accountId = prefs.getString('account_id');
      
      print('[AppStartup] Loaded webhook_url: ${webhookUrl != null ? "exists (${webhookUrl.length} chars)" : "null"}');
      print('[AppStartup] Loaded account_id: ${accountId ?? "null"}');
      
      setState(() {
        _hasWebhook = webhookUrl != null && webhookUrl.isNotEmpty;
        _isLoading = false;
      });
      
      print('[AppStartup] Navigation decision: hasWebhook=$_hasWebhook');
    } catch (e) {
      print('[AppStartup ERROR] Error checking setup: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return _hasWebhook 
        ? const FileBrowserScreen() 
        : const SetupScreen();
  }
}
