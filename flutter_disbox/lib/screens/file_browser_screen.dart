import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';

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

  /// Download a file
  Future<void> _downloadFile(DisboxFile file) async {
    // Get downloads directory - use public Downloads folder
    Directory? directory;
    
    // Try to get the public Downloads directory first
    try {
      // For Android 10+ we need to use external storage directories
      final externalDirs = await getExternalStorageDirectories(
        type: StorageDirectory.downloads,
      );
      if (externalDirs != null && externalDirs.isNotEmpty) {
        directory = externalDirs.first;
      }
    } catch (e) {
      print('Error getting downloads directory: $e');
    }
    
    // Fallback to app's external storage directory
    if (directory == null) {
      directory = await getExternalStorageDirectory();
    }
    
    if (directory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot access storage')),
      );
      return;
    }

    final outputPath = '${directory.path}/${file.name}';
    
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
      await _disboxService.downloadFile(
        file,
        outputPath,
        onProgress: (current, total) {
          // Progress is already being sent via the stream
        },
      );

      if (mounted) Navigator.pop(context); // Close progress dialog
      
      // Show success message with option to open file
      if (mounted) {
        final openResult = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Download Complete'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('File downloaded successfully!'),
                const SizedBox(height: 8),
                Text(
                  'Location: ${outputPath}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Size: ${_formatFileSize(file.size)}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('OK'),
              ),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Open File'),
              ),
            ],
          ),
        );
        
        if (openResult == true) {
          // Try to open the file
          final result = await OpenFile.open(outputPath);
          if (result.type != ResultType.done) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Cannot open file: ${result.message}')),
              );
            }
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved to: $outputPath'),
              action: SnackBarAction(
                label: 'Open',
                onPressed: () => OpenFile.open(outputPath),
              ),
            ),
          );
        }
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
                // TODO: Implement share functionality
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Share feature coming soon')),
                );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentPath == '/' ? 'Disbox' : _currentPath),
        actions: [
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
