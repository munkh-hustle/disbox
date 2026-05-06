import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import '../models/disbox_file.dart';
import '../utils/chunk_utils.dart';

/// Callback for upload/download progress updates
typedef ProgressCallback = void Function(int current, int total);

/// Main service class for interacting with Discord webhooks as cloud storage.
/// 
/// This class handles all communication with Discord's API to store and retrieve
/// files using webhooks. All operations are performed client-side - the webhook
/// URL is never sent to any third-party server.
class DisboxService {
  final Dio _dio;
  String? _webhookUrl;
  String? _accountId; // Hash of webhook URL for local identification
  
  // Cache for file metadata (in production, use Hive or SharedPreferences)
  final Map<String, DisboxFile> _fileCache = {};

  DisboxService() : _dio = Dio() {
    _dio.options.connectTimeout = const Duration(minutes: 2);
    _dio.options.receiveTimeout = const Duration(minutes: 5);
    _dio.options.sendTimeout = const Duration(minutes: 5);
    
    // Add interceptor for logging and error handling
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        print('[DIO] ${options.method} ${options.path}');
        return handler.next(options);
      },
      onError: (error, handler) {
        print('[DIO ERROR] ${error.message}');
        return handler.next(error);
      },
    ));
  }

  /// Set the webhook URL and generate account ID from it.
  /// 
  /// The webhook URL is stored locally only and never sent to third parties.
  /// The account ID is a SHA256 hash of the webhook URL for local identification.
  Future<void> setWebhookUrl(String webhookUrl) async {
    // Validate webhook URL format
    if (!_isValidWebhookUrl(webhookUrl)) {
      throw FormatException('Invalid Discord webhook URL format');
    }
    
    _webhookUrl = webhookUrl;
    _accountId = _hashWebhookUrl(webhookUrl);
    
    // Save webhook URL securely (in production, use flutter_secure_storage)
    // await secureStorage.write(key: 'webhook_url', value: webhookUrl);
    // await secureStorage.write(key: 'account_id', value: _accountId);
  }

  /// Check if webhook URL is configured
  bool get isConfigured => _webhookUrl != null;

  /// Get the account ID (hashed webhook URL)
  String? get accountId => _accountId;

  /// Extract webhook ID and token from URL
  /// 
  /// Discord webhook URL format: https://discord.com/api/webhooks/{id}/{token}
  _WebhookCredentials? _parseWebhookUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      
      // Find 'webhooks' segment and get the next two segments
      final webhookIndex = segments.indexOf('webhooks');
      if (webhookIndex == -1 || webhookIndex + 2 >= segments.length) {
        return null;
      }
      
      final id = segments[webhookIndex + 1];
      final token = segments[webhookIndex + 2];
      
      return _WebhookCredentials(id: id, token: token);
    } catch (e) {
      return null;
    }
  }

  /// Validate webhook URL format
  bool _isValidWebhookUrl(String url) {
    return _parseWebhookUrl(url) != null;
  }

  /// Hash webhook URL using SHA256 for local account identification
  String _hashWebhookUrl(String url) {
    final bytes = utf8.encode(url);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16); // Use first 16 chars
  }

  /// Get the base URL for webhook API calls
  String _getWebhookApiUrl() {
    if (_webhookUrl == null) {
      throw StateError('Webhook URL not configured');
    }
    
    final creds = _parseWebhookUrl(_webhookUrl!);
    if (creds == null) {
      throw StateError('Invalid webhook URL');
    }
    
    return '${DisboxConstants.discordApiBase}/${creds.id}/${creds.token}';
  }

  // ==================== FILE OPERATIONS ====================

  /// Upload a file to Discord via webhook.
  /// 
  /// Files larger than 25MB are automatically split into chunks.
  /// Each chunk is uploaded as a separate Discord message attachment.
  /// Metadata about the file (name, path, chunk IDs) is stored in a metadata message.
  /// 
  /// [file] - The file to upload
  /// [folderPath] - The virtual folder path in Disbox (e.g., "/documents")
  /// [onProgress] - Optional callback for upload progress
  /// 
  /// Returns the [DisboxFile] metadata object
  Future<DisboxFile> uploadFile(
    File file, {
    String folderPath = '/',
    ProgressCallback? onProgress,
  }) async {
    if (!isConfigured) {
      throw StateError('Webhook URL not configured');
    }

    final filename = path.basename(file.path);
    final filePath = _normalizePath('$folderPath/$filename');
    final fileSize = file.lengthSync();
    final mimeType = _detectMimeType(filename);
    
    print('Uploading: $filename ($fileSize bytes) to $filePath');

    // Determine if we need to chunk the file
    final needsChunking = fileSize > DisboxConstants.maxAttachmentSize;
    final chunkMessageIds = <String>[];
    
    if (needsChunking) {
      // Upload as chunks
      final chunks = ChunkUtils.splitFile(file);
      print('File requires chunking: ${chunks.length} chunks');
      
      var uploadedBytes = 0;
      
      for (int i = 0; i < chunks.length; i++) {
        final chunkData = await ChunkUtils.readChunk(file, i);
        
        print('Uploading chunk ${i + 1}/${chunks.length}');
        
        final messageId = await _uploadAttachment(
          chunkData,
          filename: '${filename}.part$i',
          contentType: 'application/octet-stream',
        );
        
        chunkMessageIds.add(messageId);
        uploadedBytes += chunkData.length;
        
        onProgress?.call(uploadedBytes, fileSize);
      }
    } else {
      // Upload as single file
      final fileBytes = await file.readAsBytes();
      
      final messageId = await _uploadAttachment(
        fileBytes,
        filename: filename,
        contentType: mimeType,
      );
      
      chunkMessageIds.add(messageId);
      onProgress?.call(fileSize, fileSize);
    }

    // Create metadata message to store file information
    final metadataMessageId = await _createMetadataMessage(
      filename: filename,
      path: filePath,
      size: fileSize,
      mimeType: mimeType,
      chunkMessageIds: chunkMessageIds,
      isFolder: false,
    );

    // Create and cache DisboxFile object
    final disboxFile = DisboxFile(
      id: metadataMessageId,
      name: filename,
      path: filePath,
      isFolder: false,
      size: fileSize,
      mimeType: mimeType,
      chunkMessageIds: chunkMessageIds,
      createdAt: DateTime.now(),
      modifiedAt: DateTime.now(),
      parentId: _getParentFolderId(folderPath),
    );

    _fileCache[disboxFile.id] = disboxFile;
    
    return disboxFile;
  }

  /// Download a file from Discord.
  /// 
  /// For chunked files, downloads all chunks and reassembles them.
  /// 
  /// [file] - The DisboxFile metadata object
  /// [outputPath] - Where to save the downloaded file
  /// [onProgress] - Optional callback for download progress
  Future<File> downloadFile(
    DisboxFile file,
    String outputPath, {
    ProgressCallback? onProgress,
  }) async {
    if (!isConfigured) {
      throw StateError('Webhook URL not configured');
    }

    if (file.isFolder) {
      throw ArgumentError('Cannot download a folder');
    }

    print('Downloading: ${file.name} (${file.chunkMessageIds.length} chunks)');

    final chunks = <(int, Uint8List)>[];
    var downloadedBytes = 0;
    final totalBytes = file.size ?? 0;

    // Download each chunk
    for (int i = 0; i < file.chunkMessageIds.length; i++) {
      final messageId = file.chunkMessageIds[i];
      
      print('Downloading chunk ${i + 1}/${file.chunkMessageIds.length}');
      
      final chunkData = await _downloadAttachment(messageId);
      chunks.add((i, chunkData));
      downloadedBytes += chunkData.length;
      
      onProgress?.call(downloadedBytes, totalBytes);
    }

    // Reassemble chunks
    await ChunkUtils.assembleChunks(chunks, outputPath);
    
    print('Download complete: $outputPath');
    
    return File(outputPath);
  }

  /// Delete a file or folder.
  /// 
  /// Deletes all chunk messages and the metadata message.
  Future<void> deleteFile(DisboxFile file) async {
    if (!isConfigured) {
      throw StateError('Webhook URL not configured');
    }

    print('Deleting: ${file.name}');

    // Delete all chunk messages
    for (final messageId in file.chunkMessageIds) {
      try {
        await _deleteMessage(messageId);
      } catch (e) {
        print('Warning: Failed to delete chunk $messageId: $e');
      }
    }

    // Delete metadata message
    try {
      await _deleteMessage(file.id);
    } catch (e) {
      print('Warning: Failed to delete metadata message ${file.id}: $e');
    }

    // Remove from cache
    _fileCache.remove(file.id);
  }

  /// List files in a folder.
  /// 
  /// Fetches metadata messages and returns DisboxFile objects.
  /// 
  /// [folderPath] - The virtual folder path to list (default: root "/")
  Future<List<DisboxFile>> listFiles({String folderPath = '/'}) async {
    if (!isConfigured) {
      throw StateError('Webhook URL not configured');
    }

    print('Listing files in: $folderPath');

    // Fetch all messages from the webhook
    final messages = await _fetchMessages();
    
    // Filter for metadata messages in this folder
    final files = <DisboxFile>[];
    
    for (final message in messages) {
      // Skip non-metadata messages
      if (!_isMetadataMessage(message)) continue;
      
      try {
        final metadata = _parseMetadataMessage(message);
        
        // Filter by folder path
        final parentPath = _getParentPath(metadata.path);
        if (parentPath == folderPath || 
            (folderPath == '/' && parentPath.isEmpty)) {
          files.add(metadata);
        }
      } catch (e) {
        print('Warning: Failed to parse metadata message: $e');
      }
    }

    // Sort: folders first, then files, alphabetically
    files.sort((a, b) {
      if (a.isFolder && !b.isFolder) return -1;
      if (!a.isFolder && b.isFolder) return 1;
      return a.name.compareTo(b.name);
    });

    return files;
  }

  /// Create a folder (virtual - stored as metadata message).
  Future<DisboxFile> createFolder(String name, {String parentPath = '/'}) async {
    if (!isConfigured) {
      throw StateError('Webhook URL not configured');
    }

    final folderPath = _normalizePath('$parentPath/$name');
    
    print('Creating folder: $name at $folderPath');

    // Create metadata message for folder
    final metadataMessageId = await _createMetadataMessage(
      filename: name,
      path: folderPath,
      size: 0,
      mimeType: null,
      chunkMessageIds: [],
      isFolder: true,
    );

    final folder = DisboxFile(
      id: metadataMessageId,
      name: name,
      path: folderPath,
      isFolder: true,
      size: 0,
      createdAt: DateTime.now(),
      modifiedAt: DateTime.now(),
      parentId: _getParentFolderId(parentPath),
    );

    _fileCache[folder.id] = folder;
    
    return folder;
  }

  /// Rename a file or folder.
  Future<DisboxFile> renameFile(DisboxFile file, String newName) async {
    if (!isConfigured) {
      throw StateError('Webhook URL not configured');
    }

    final parentPath = _getParentPath(file.path);
    final newPath = _normalizePath('$parentPath/$newName');
    
    print('Renaming: ${file.name} -> $newName');

    // Update metadata message
    await _updateMetadataMessage(file.id, {
      'name': newName,
      'path': newPath,
    });

    // Update cached object
    final updatedFile = DisboxFile(
      id: file.id,
      name: newName,
      path: newPath,
      isFolder: file.isFolder,
      size: file.size,
      mimeType: file.mimeType,
      chunkMessageIds: file.chunkMessageIds,
      createdAt: file.createdAt,
      modifiedAt: DateTime.now(),
      parentId: file.parentId,
    );

    _fileCache[updatedFile.id] = updatedFile;
    
    return updatedFile;
  }

  // ==================== DISCORD API METHODS ====================

  /// Upload an attachment to Discord via webhook.
  /// 
  /// Returns the message ID of the created message.
  Future<String> _uploadAttachment(
    Uint8List data, {
    required String filename,
    required String contentType,
  }) async {
    final apiUrl = _getWebhookApiUrl();
    
    // Create multipart form data
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        data,
        filename: filename,
        contentType: DioMediaType.parse(contentType),
      ),
      // Wait=false means don't wait for message processing
      'wait': 'true',
    });

    final response = await _dio.post(
      apiUrl,
      data: formData,
      queryParameters: {'wait': 'true'},
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to upload attachment: ${response.statusCode}');
    }

    final responseData = response.data as Map<String, dynamic>;
    return responseData['id'] as String;
  }

  /// Download an attachment from a Discord message.
  Future<Uint8List> _downloadAttachment(String messageId) async {
    final apiUrl = _getWebhookApiUrl();
    
    // Fetch the message to get attachment URL
    final response = await _dio.get(
      '$apiUrl/messages/$messageId',
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch message: ${response.statusCode}');
    }

    final responseData = response.data as Map<String, dynamic>;
    final attachments = responseData['attachments'] as List<dynamic>;
    
    if (attachments.isEmpty) {
      throw Exception('No attachments found in message $messageId');
    }

    final attachmentUrl = attachments[0]['url'] as String;
    
    // Download the actual file
    final fileResponse = await _dio.get(
      attachmentUrl,
      options: Options(responseType: ResponseType.bytes),
    );

    return fileResponse.data as Uint8List;
  }

  /// Delete a Discord message.
  Future<void> _deleteMessage(String messageId) async {
    final apiUrl = _getWebhookApiUrl();
    
    await _dio.delete('$apiUrl/messages/$messageId');
  }

  /// Fetch messages from the webhook channel.
  /// 
  /// Note: This requires fetching from the channel, not the webhook directly.
  /// In production, you may need to store channel ID separately or use
  /// a different approach for listing files.
  Future<List<Map<String, dynamic>>> _fetchMessages() async {
    // For MVP, we'll return empty list
    // In production, you'd need to:
    // 1. Store channel ID when webhook is created
    // 2. Use Discord API to fetch channel messages
    // 3. Filter for metadata messages
    
    print('Warning: Message fetching not fully implemented for MVP');
    return [];
  }

  /// Create a metadata message to store file information.
  /// 
  /// Encodes file metadata as JSON in the message content.
  Future<String> _createMetadataMessage({
    required String filename,
    required String path,
    required int size,
    String? mimeType,
    required List<String> chunkMessageIds,
    required bool isFolder,
  }) async {
    final apiUrl = _getWebhookApiUrl();
    
    final metadata = {
      'type': 'disbox_metadata',
      'version': '1.0',
      'name': filename,
      'path': path,
      'size': size,
      'mimeType': mimeType,
      'chunkIds': chunkMessageIds,
      'isFolder': isFolder,
      'createdAt': DateTime.now().toIso8601String(),
    };

    final response = await _dio.post(
      apiUrl,
      data: {
        'content': '${DisboxConstants.boxPrefix} ${jsonEncode(metadata)}',
      },
      queryParameters: {'wait': 'true'},
    );

    final responseData = response.data as Map<String, dynamic>;
    return responseData['id'] as String;
  }

  /// Update a metadata message.
  Future<void> _updateMetadataMessage(String messageId, Map<String, dynamic> updates) async {
    final apiUrl = _getWebhookApiUrl();
    
    // Fetch current metadata
    final currentMessage = await _dio.get('$apiUrl/messages/$messageId');
    final content = currentMessage.data['content'] as String;
    
    if (!content.startsWith(DisboxConstants.boxPrefix)) {
      throw Exception('Not a metadata message');
    }
    
    final jsonStr = content.substring(DisboxConstants.boxPrefix.length).trim();
    final metadata = jsonDecode(jsonStr) as Map<String, dynamic>;
    
    // Apply updates
    metadata.addAll(updates);
    metadata['modifiedAt'] = DateTime.now().toIso8601String();
    
    // Update message
    await _dio.patch(
      '$apiUrl/messages/$messageId',
      data: {
        'content': '${DisboxConstants.boxPrefix} ${jsonEncode(metadata)}',
      },
    );
  }

  /// Check if a message is a Disbox metadata message.
  bool _isMetadataMessage(Map<String, dynamic> message) {
    final content = message['content'] as String?;
    return content?.startsWith(DisboxConstants.boxPrefix) ?? false;
  }

  /// Parse metadata from a message.
  DisboxFile _parseMetadataMessage(Map<String, dynamic> message) {
    final content = message['content'] as String;
    final jsonStr = content.substring(DisboxConstants.boxPrefix.length).trim();
    final metadata = jsonDecode(jsonStr) as Map<String, dynamic>;
    
    return DisboxFile(
      id: message['id'] as String,
      name: metadata['name'] as String,
      path: metadata['path'] as String,
      isFolder: metadata['isFolder'] as bool,
      size: metadata['size'] as int?,
      mimeType: metadata['mimeType'] as String?,
      chunkMessageIds: (metadata['chunkIds'] as List?)?.cast<String>() ?? [],
      createdAt: DateTime.parse(metadata['createdAt'] as String),
      modifiedAt: metadata['modifiedAt'] != null
          ? DateTime.parse(metadata['modifiedAt'] as String)
          : DateTime.parse(metadata['createdAt'] as String),
    );
  }

  // ==================== UTILITY METHODS ====================

  /// Normalize a path (ensure starts with /, no trailing /, no double slashes)
  String _normalizePath(String path) {
    var normalized = path.replaceAll('//', '/');
    if (!normalized.startsWith('/')) {
      normalized = '/$normalized';
    }
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Get parent path from a full path
  String _getParentPath(String fullPath) {
    final parts = fullPath.split('/');
    if (parts.length <= 1) return '';
    return parts.sublist(0, parts.length - 1).join('/') ;
  }

  /// Get parent folder ID from path (simplified for MVP)
  String? _getParentFolderId(String folderPath) {
    // In production, you'd look up the parent folder's message ID
    return null;
  }

  /// Detect MIME type from filename extension
  String _detectMimeType(String filename) {
    final ext = path.extension(filename).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.pdf':
        return 'application/pdf';
      case '.txt':
        return 'text/plain';
      case '.mp4':
        return 'video/mp4';
      case '.mp3':
        return 'audio/mpeg';
      default:
        return 'application/octet-stream';
    }
  }
}

/// Helper class to hold parsed webhook credentials
class _WebhookCredentials {
  final String id;
  final String token;

  _WebhookCredentials({required this.id, required this.token});
}
