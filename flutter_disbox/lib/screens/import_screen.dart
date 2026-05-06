import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/disbox_service.dart';
import 'file_browser_screen.dart';
import 'manual_setup_screen.dart';

/// Screen for importing webhook configuration from a JSON file.
/// 
/// This screen allows users to select a JSON config file containing
/// their Discord webhook URL instead of manually entering it.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _pickAndImportFile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Pick JSON file
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        
        // Import config using DisboxService
        final service = DisboxService();
        final success = await service.importConfig(file);

        if (success && mounted) {
          // Navigate to main screen
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const FileBrowserScreen()),
          );
        } else if (mounted) {
          setState(() {
            _errorMessage = 'Failed to import config. Please check the JSON file format.';
          });
        }
      } else if (mounted) {
        setState(() {
          _errorMessage = 'No file selected';
        });
      }
    } catch (e) {
      print('[IMPORT ERROR] Exception: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Error: ${e.toString()}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('How to Import Config'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Export your config from another device or create a JSON file with:'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '{\n  "webhook_url": "https://discord.com/api/webhooks/..."\n}',
                style: TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const SizedBox(height: 16),
            const Text('2. Tap "Select JSON File" below'),
            const SizedBox(height: 8),
            const Text('3. Choose your config file'),
            const SizedBox(height: 8),
            const Text('4. The app will automatically load your webhook and files'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Configuration'),
        leading: IconButton(
          icon: const Icon(Icons.help_outline),
          onPressed: _showHelpDialog,
          tooltip: 'First time? Get help here',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showHelpDialog,
            tooltip: 'Help',
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_upload_outlined,
                size: 80,
                color: Theme.of(context).primaryColor,
              ),
              const SizedBox(height: 24),
              const Text(
                'Import Webhook Config',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Select a JSON file containing your Discord webhook URL to get started.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 40),
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red[200]!),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red[700]),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: Colors.red[700]),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _pickAndImportFile,
                icon: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open),
                label: Text(_isLoading ? 'Importing...' : 'Select JSON File'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  textStyle: const TextStyle(fontSize: 16),
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () {
                  // Navigate to manual setup
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ManualSetupScreen()),
                  );
                },
                icon: const Icon(Icons.edit),
                label: const Text('Manual Setup (First Time Users)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
