import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_file/open_file.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;

import '../services/disbox_service.dart';
import '../models/disbox_file.dart';
import '../widgets/file_list_tile.dart';
import '../widgets/progress_dialog.dart';

/// Main file browser screen for Disbox.
/// 
/// Displays files and folders, allows navigation, upload, download, delete, etc.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  late final DisboxService _disboxService;
  
  List<DisboxFile> _files = [];
  String _currentPath = '/';
  bool _isLoading = false;
  String? _error;
  bool _isInitialized = false;
  bool _isPickingFile = false; // Prevent multiple file picker invocations

  @override
  void initState() {
    super.initState();
    _disboxService = DisboxService();
    _initializeService();
  }

  /// Initialize the service with the saved webhook URL
  Future<void> _initializeService() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      print('[DEBUG] Initializing DisboxService...');
      
      // Load webhook URL from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final webhookUrl = prefs.getString('webhook_url');
      final accountId = prefs.getString('account_id');
      
      print('[DEBUG] Loaded webhook_url: ${webhookUrl != null ? "exists" : "null"}');
      print('[DEBUG] Loaded account_id: ${accountId ?? "null"}');
      
      if (webhookUrl == null || webhookUrl.isEmpty) {
        throw Exception('No webhook URL configured. Please set up your webhook URL first.');
      }
      
      // Set the webhook URL in the service (this also loads the file tree from Hive)
      await _disboxService.setWebhookUrl(webhookUrl);
      
      print('[DEBUG] Service initialized successfully');
      print('[DEBUG] Service isConfigured: ${_disboxService.isConfigured}');
      print('[DEBUG] Service accountId: ${_disboxService.accountId ?? "null"}');
      
      setState(() {
        _isInitialized = true;
      });
      
      // Now load files
      await _loadFiles();
    } catch (e) {
      print('[DEBUG ERROR] Failed to initialize service: $e');
      setState(() {
        _error = 'Initialization error: $e';
        _isLoading = false;
      });
    }
  }

  /// Load files in current folder
  Future<void> _loadFiles() async {
    if (!_isInitialized) {
      print('[DEBUG] Cannot load files: service not initialized yet');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      print('[DEBUG] Loading files from path: $_currentPath');
      
      // Fetch files from backend server via DisboxService
      final files = await _disboxService.listFiles(folderPath: _currentPath);
      
      print('[DEBUG] Loaded ${files.length} files');
      
      setState(() {
        _files = files;
        _isLoading = false;
      });
    } catch (e) {
      print('[DEBUG ERROR] Failed to load files: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Navigate to a folder
  void _navigateToFolder(String path) {
    setState(() {
      _currentPath = path;
    });
    _loadFiles();
  }

  /// Navigate to parent folder
  void _navigateUp() {
    if (_currentPath == '/') return;
    
    final parts = _currentPath.split('/');
    parts.removeLast();
    final parentPath = parts.join('/') ;
    
    _navigateToFolder(parentPath.isEmpty ? '/' : parentPath);
  }

  /// Upload a file
  Future<void> _uploadFile() async {
    // Prevent multiple simultaneous file picker invocations
    if (_isPickingFile) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File picker is already open')),
      );
      return;
    }

    try {
      setState(() => _isPickingFile = true);
      
      // Pick file from device
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.first.path;
      if (filePath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to access file path')),
        );
        return;
      }

      final file = File(filePath);
      
      // Check file size and warn for very large files
      final fileSize = await file.length();
      final fileSizeMB = fileSize / (1024 * 1024);
      
      if (fileSizeMB > 500) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Large File Warning'),
            content: Text(
              'The file you selected is ${fileSizeMB.toStringAsFixed(1)} MB. '
              'Uploading large files may take a long time and could fail due to network issues or rate limits.\n\n'
              'Do you want to continue?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
        
        if (confirmed != true) return;
      }
      
      // Create a controller for progress updates
      double currentProgress = 0.0;
      
      // Show progress dialog with stream
      final progressDialog = ProgressDialog(
        title: 'Uploading ${result.files.first.name}',
        message: '${fileSizeMB.toStringAsFixed(1)} MB - Please wait...',
        initialProgress: 0.0,
        progressStream: _disboxService.uploadProgress,
      );
      
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => progressDialog,
      );

      try {
        await _disboxService.uploadFile(
          file,
          folderPath: _currentPath,
          onProgress: (current, total) {
            setState(() {
              currentProgress = current / total;
            });
          },
        );

        if (mounted) Navigator.pop(context); // Close progress dialog
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File uploaded successfully')),
        );
        
        _loadFiles(); // Refresh file list
      } catch (e) {
        if (mounted) Navigator.pop(context); // Close progress dialog
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking file: $e')),
      );
    } finally {
      if (mounted) setState(() => _isPickingFile = false);
    }
  }

  /// Create a new folder
  Future<void> _createFolder() async {
    final controller = TextEditingController();
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            hintText: 'Enter folder name',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (confirmed != true || controller.text.trim().isEmpty) return;

    try {
      await _disboxService.createFolder(
        controller.text.trim(),
        parentPath: _currentPath,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Folder created')),
      );
      
      _loadFiles(); // Refresh file list
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create folder: $e')),
      );
    }
  }

  /// Download a file to Documents folder using file_saver package
  Future<void> _downloadFile(DisboxFile file) async {
    // Show progress dialog with stream
    final progressDialog = ProgressDialog(
      title: 'Downloading ${file.name}',
      message: 'Preparing download...',
      initialProgress: 0.0,
      progressStream: _disboxService.downloadProgress,
    );
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => progressDialog,
    );

    try {
      // Request storage permission for Android 12 and below
      if (Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        if (androidInfo.version.sdkInt <= 28) {
          var status = await Permission.storage.status;
          if (!status.isGranted) {
            status = await Permission.storage.request();
            if (!status.isGranted) {
              throw Exception('Storage permission is required to save files');
            }
          }
        } else if (androidInfo.version.sdkInt >= 30) {
          // For Android 11+, request MANAGE_EXTERNAL_STORAGE
          var status = await Permission.manageExternalStorage.status;
          if (!status.isGranted) {
            status = await Permission.manageExternalStorage.request();
            if (!status.isGranted) {
              throw Exception('Manage external storage permission is required');
            }
          }
        }
      }

      // Download to temporary file first
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/${file.name}';
      
      await _disboxService.downloadFile(
        file,
        tempPath,
        onProgress: (current, total) {
          // Progress is already being sent via the stream
        },
      );

      if (mounted) Navigator.pop(context); // Close progress dialog
      
      // Read the downloaded file
      final fileData = await File(tempPath).readAsBytes();
      
      print('[FileCopy] Saving file: ${file.name} (${fileData.length} bytes)');
      
      // Save to public Documents folder
      String? savedPath;
      String savedFileName = file.name; // Track the final saved filename
      try {
        // Try to access the public Documents directory
        Directory? documentsDir;
        
        if (Platform.isAndroid) {
          final androidInfo = await DeviceInfoPlugin().androidInfo;
          if (androidInfo.version.sdkInt >= 29) {
            // For Android 10+, use the specific path to Documents
            documentsDir = Directory('/storage/emulated/0/Documents/Disbox');
          } else {
            // For older versions, use external storage directory
            documentsDir = Directory('/storage/emulated/0/Documents/Disbox');
          }
        } else {
          documentsDir = await getApplicationDocumentsDirectory();
        }
        
        // Create the Disbox subdirectory if it doesn't exist
        if (!await documentsDir.exists()) {
          await documentsDir.create(recursive: true);
        }
        
        // Generate unique filename if file already exists
        String finalFileName = file.name;
        String finalFilePath = '${documentsDir.path}/$finalFileName';
        int counter = 1;
        
        while (await File(finalFilePath).exists()) {
          final nameParts = file.name.split('.');
          if (nameParts.length > 1) {
            final ext = nameParts.removeLast();
            final baseName = nameParts.join('.');
            finalFileName = '${baseName}_$counter.$ext';
          } else {
            finalFileName = '${file.name}_$counter';
          }
          finalFilePath = '${documentsDir.path}/$finalFileName';
          counter++;
        }
        
        // Update savedFileName for the success message
        savedFileName = finalFileName;
        
        // Write the file
        final savedFile = File(finalFilePath);
        await savedFile.writeAsBytes(fileData);
        savedPath = savedFile.path;
        
        print('[FileCopy] File saved to: $savedPath');
        
        // Notify media scanner about the new file (for Android)
        if (Platform.isAndroid) {
          // This helps the file appear in gallery/file manager apps
          // We can't directly call MediaScannerConnection here without platform channel
          // But creating the file in Documents should be enough
        }
      } catch (e) {
        print('[FileCopy ERROR] Failed to save file: $e');
        rethrow;
      }
      
      // Clean up temporary file
      try {
        await File(tempPath).delete();
      } catch (e) {
        print('Warning: Could not delete temp file: $e');
      }
      
      // Show success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$savedFileName saved to Documents/Disbox'),
            action: SnackBarAction(
              label: 'OK',
              onPressed: () {},
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context); // Close progress dialog
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }
  
  /// Format file size for display
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Delete a file or folder
  Future<void> _deleteFile(DisboxFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Are you sure you want to delete "${file.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _disboxService.deleteFile(file);
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deleted successfully')),
      );
      
      _loadFiles(); // Refresh file list
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  /// Show file/folder options menu
  void _showOptions(DisboxFile file) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Details'),
              onTap: () {
                Navigator.pop(context);
                _showDetails(file);
              },
            ),
            if (!file.isFolder)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(context);
                  _downloadFile(file);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(context);
                _renameFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Share'),
              onTap: () {
                Navigator.pop(context);
                _shareMetadata(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _deleteFile(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Rename a file or folder
  Future<void> _renameFile(DisboxFile file) async {
    final controller = TextEditingController(text: file.name);
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'New name',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (confirmed != true || controller.text.trim().isEmpty) return;

    try {
      await _disboxService.renameFile(file, controller.text.trim());
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Renamed successfully')),
      );
      
      _loadFiles(); // Refresh file list
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rename failed: $e')),
      );
    }
  }

  /// Show file details dialog
  void _showDetails(DisboxFile file) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(file.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow('Type', file.isFolder ? 'Folder' : 'File'),
            _buildDetailRow('Size', file.formattedSize),
            _buildDetailRow('Path', file.path),
            _buildDetailRow(
              'Created',
              '${file.createdAt.day}/${file.createdAt.month}/${file.createdAt.year}',
            ),
            if (!file.isFolder && file.chunkMessageIds.length > 1)
              _buildDetailRow('Chunks', '${file.chunkMessageIds.length} parts'),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  /// Export metadata (webhook URL and account ID) to share with another device
  Future<void> _exportMetadata() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final webhookUrl = prefs.getString('webhook_url');
      final accountId = prefs.getString('account_id');
      
      if (webhookUrl == null || accountId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No configuration found to export')),
        );
        return;
      }
      
      // Get the entire file tree from local storage as a list of DisboxFile
      final fileList = await _service.getFileTreeList();
      
      // Convert DisboxFile list to JSON-serializable format
      final fileListJson = fileList.map((file) => file.toJson()).toList();

      // Create JSON data with config AND file tree
      final jsonData = jsonEncode({
        'webhook_url': webhookUrl,
        'account_id': accountId,
        'exported_at': DateTime.now().toIso8601String(),
        'version': '2.0',
        'file_tree': fileListJson,
      });
      
      // Share the JSON data
      final result = await Share.shareXFiles(
        [XFile.fromData(
          Uint8List.fromList(jsonData.codeUnits),
          name: 'disbox_config.json',
          mimeType: 'application/json',
        )],
        subject: 'Disbox Configuration',
        text: 'Disbox configuration file with file tree. Import this on your other device to sync your Disbox storage.',
      );
      
      if (result.status == ShareResultStatus.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuration exported successfully')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  /// Import metadata from a shared config file
  Future<void> _importMetadata() async {
    try {
      // Pick the config file
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );
      
      if (result == null || result.files.isEmpty) {
        return;
      }
      
      final filePath = result.files.first.path;
      if (filePath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to access selected file')),
        );
        return;
      }
      
      // Read and parse the file
      final fileContent = await File(filePath).readAsString();
      final data = jsonDecode(fileContent) as Map<String, dynamic>;
      
      // Validate the data
      if (!data.containsKey('webhook_url') || !data.containsKey('account_id')) {
        throw Exception('Invalid configuration file format');
      }
      
      // Trim whitespace from webhook URL (common issue when copying/sharing)
      final webhookUrl = (data['webhook_url'] as String).trim();
      final accountId = (data['account_id'] as String).trim();
      
      // Confirm import
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import Configuration'),
          content: Text(
            'This will replace your current Disbox configuration with the one from the file.\n\n'
            'Account ID: ${accountId.substring(0, math.min(20, accountId.length))}...\n\n'
            'Do you want to continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      
      if (confirmed != true) {
        return;
      }
      
      // Save the new configuration
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('webhook_url', webhookUrl);
      await prefs.setString('account_id', accountId);

      // Import file tree if available (version 2.0+)
      if (data.containsKey('file_tree') && data['file_tree'] is List) {
        final fileListJson = data['file_tree'] as List;
        
        // Convert JSON list to DisboxFile objects
        final fileList = <DisboxFile>[];
        for (final item in fileListJson) {
          if (item is Map<String, dynamic>) {
            fileList.add(DisboxFile.fromJson(item));
          }
        }
        
        // Save the imported file tree to local storage
        await _disboxService.saveFileTreeFromList(fileList);
      }
      
      
      // Reinitialize the service with the new configuration
      await _disboxService.setWebhookUrl(webhookUrl);
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuration and files imported successfully')),
      );
      
      // Reload files
      setState(() {
        _currentPath = '/';
      });
      await _loadFiles();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  /// Share metadata for a specific file (for advanced users)
  Future<void> _shareMetadata(DisboxFile file) async {
    try {
      // Create JSON data for the file
      final jsonData = jsonEncode({
        'name': file.name,
        'path': file.path,
        'isFolder': file.isFolder,
        'size': file.size,
        'createdAt': file.createdAt.toIso8601String(),
        'chunkMessageIds': file.chunkMessageIds,
        'version': '1.0',
      });
      
      // Share the JSON data
      await Share.shareXFiles(
        [XFile.fromData(
          Uint8List.fromList(jsonData.codeUnits),
          name: '${file.name}.meta.json',
          mimeType: 'application/json',
        )],
        subject: 'Disbox File Metadata: ${file.name}',
        text: 'Metadata for file "${file.name}" from Disbox.',
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentPath == '/' ? 'Disbox' : _currentPath),
        actions: [
          IconButton(
            icon: const Icon(Icons.import_export),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (context) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.upload_file, color: Colors.blue),
                        title: const Text('Export Configuration'),
                        subtitle: const Text('Share webhook URL to another device'),
                        onTap: () {
                          Navigator.pop(context);
                          _exportMetadata();
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.download, color: Colors.green),
                        title: const Text('Import Configuration'),
                        subtitle: const Text('Load config from shared file'),
                        onTap: () {
                          Navigator.pop(context);
                          _importMetadata();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
            tooltip: 'Export/Import',
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _createFolder,
            tooltip: 'New Folder',
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            onPressed: _uploadFile,
            tooltip: 'Upload File',
          ),
        ],
      ),
      body: Column(
        children: [
          // Breadcrumb navigation
          if (_currentPath != '/')
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _navigateUp,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 8),
                  const Text('↑ Go up'),
                ],
              ),
            ),
          
          // File list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                            const SizedBox(height: 16),
                            Text('Error: $_error'),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadFiles,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : _files.isEmpty
                        ? const Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.folder_open, size: 64, color: Colors.grey),
                                SizedBox(height: 16),
                                Text(
                                  'No files here',
                                  style: TextStyle(fontSize: 18, color: Colors.grey),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Tap + to upload files or create folders',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: _files.length,
                            itemBuilder: (context, index) {
                              final file = _files[index];
                              return FileListTile(
                                file: file,
                                onTap: () {
                                  if (file.isFolder) {
                                    _navigateToFolder(file.path);
                                  } else {
                                    _showOptions(file);
                                  }
                                },
                                onLongPress: () => _showOptions(file),
                              );
                            },
                          ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _uploadFile,
        child: const Icon(Icons.add),
      ),
    );
  }
}
