import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../services/chat_service.dart';
import '../services/peer_service.dart';

class ChatScreen extends StatefulWidget {
  final String roomId;
  final String encryptionKey;
  final String userName;
  final String userAvatar;

  const ChatScreen({
    super.key,
    required this.roomId,
    required this.encryptionKey,
    required this.userName,
    required this.userAvatar,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _editController = TextEditingController();
  final _scrollController = ScrollController();
  List<ChatMessage> _messages = [];
  StreamSubscription? _subscription;
  String? _userId;
  String? _editingId;
  String _timeLeft = '';
  Timer? _timer;
  final Map<String, _MediaState> _mediaStates = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final uid = await ChatService.getAnonymousUser();
    setState(() => _userId = uid);

    PeerService.startHosting(widget.roomId, uid);

    // TTL countdown
    final room = await ChatService.getRoomInfo(widget.roomId);
    if (room != null && room['createdAt'] != null) {
      final createdMs = (room['createdAt'] as dynamic).millisecondsSinceEpoch as int;
      final ttlMs = (room['ttlMinutes'] as int) * 60 * 1000;
      final expiresAt = createdMs + ttlMs;

      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        final remaining = expiresAt - DateTime.now().millisecondsSinceEpoch;
        if (remaining <= 0) {
          _timer?.cancel();
          _handleExit();
          return;
        }
        final h = remaining ~/ 3600000;
        final m = (remaining % 3600000) ~/ 60000;
        final s = (remaining % 60000) ~/ 1000;
        setState(() {
          _timeLeft = h > 0 ? '${h}h ${m}m' : m > 0 ? '${m}m ${s}s' : '${s}s';
        });
      });
    }

    _subscription = ChatService.subscribeToMessages(
      widget.roomId,
      widget.encryptionKey,
    ).listen((messages) {
      setState(() => _messages = messages);
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _userId == null) return;
    _textController.clear();

    // Optimistic update
    setState(() {
      _messages.add(ChatMessage(
        id: 'temp-${DateTime.now().millisecondsSinceEpoch}',
        text: text,
        senderId: _userId!,
        senderName: widget.userName,
        senderAvatar: widget.userAvatar,
      ));
    });
    _scrollToBottom();

    await ChatService.sendMessage(
      roomId: widget.roomId,
      text: text,
      senderId: _userId!,
      senderName: widget.userName,
      senderAvatar: widget.userAvatar,
      encryptionKey: widget.encryptionKey,
    );
  }

  Future<void> _pickAndSendFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || _userId == null) return;
    final file = result.files.single;

    Uint8List? bytes;
    if (file.bytes != null) {
      bytes = file.bytes!;
    } else if (file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) return;

    final mediaId = ChatService.generateMediaId();
    PeerService.hostFile(mediaId, bytes);

    // Local preview
    setState(() {
      _mediaStates[mediaId] = _MediaState(bytes: bytes);
    });

    await ChatService.sendMediaMessage(
      roomId: widget.roomId,
      senderId: _userId!,
      senderName: widget.userName,
      senderAvatar: widget.userAvatar,
      encryptionKey: widget.encryptionKey,
      mediaId: mediaId,
      mediaName: file.name,
      mediaType: _mimeFromExtension(file.extension ?? ''),
      mediaSize: bytes.length,
    );
  }

  void _requestMedia(ChatMessage msg) {
    if (msg.mediaId == null || _userId == null) return;

    setState(() {
      _mediaStates[msg.mediaId!] = _MediaState(loading: true, progress: 0);
    });

    PeerService.requestFile(
      roomId: widget.roomId,
      mediaId: msg.mediaId!,
      senderId: msg.senderId,
      myUserId: _userId!,
      onProgress: (pct) {
        if (mounted) {
          setState(() {
            _mediaStates[msg.mediaId!] = _MediaState(loading: true, progress: pct);
          });
        }
      },
      onComplete: (data) {
        if (mounted) {
          setState(() {
            _mediaStates[msg.mediaId!] = _MediaState(bytes: data);
          });
        }
      },
      onError: (err) {
        if (mounted) {
          setState(() {
            _mediaStates[msg.mediaId!] = _MediaState(error: err);
          });
        }
      },
    );
  }

  Future<void> _editMessage(String messageId) async {
    final text = _editController.text.trim();
    if (text.isEmpty) return;
    await ChatService.editMessage(
      roomId: widget.roomId,
      messageId: messageId,
      newText: text,
      encryptionKey: widget.encryptionKey,
    );
    setState(() => _editingId = null);
  }

  Future<void> _deleteMessage(String messageId) async {
    await ChatService.deleteMessage(widget.roomId, messageId);
  }

  Future<void> _handleExit() async {
    PeerService.stopHosting();
    try {
      await ChatService.deleteRoom(widget.roomId);
    } catch (_) {}
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  void _copyLink() {
    final link =
        'https://guestchat-922.web.app/chat/${widget.roomId}#${widget.encryptionKey}';
    Clipboard.setData(ClipboardData(text: link));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite link copied!')),
    );
  }

  String _mimeFromExtension(String ext) {
    switch (ext.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatTime(dynamic timestamp) {
    if (timestamp == null) return '';
    final date = timestamp.toDate() as DateTime;
    final h = date.hour.toString().padLeft(2, '0');
    final m = date.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWarning = _timeLeft.contains('s') && !_timeLeft.contains('m');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.exit_to_app),
          tooltip: 'Exit & Delete Room',
          onPressed: _handleExit,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Guest Chat', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            GestureDetector(
              onTap: _copyLink,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.roomId,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Share Link',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (_timeLeft.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text(
                  '⏱ $_timeLeft',
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: isWarning ? Colors.red : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.userAvatar, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 4),
                Container(width: 8, height: 8, decoration: const BoxDecoration(
                  color: Colors.green, shape: BoxShape.circle,
                )),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // E2E badge
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6),
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
            child: Text(
              '🔒 End-to-end encrypted — media shared peer-to-peer',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          // Messages
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('No messages yet',
                            style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 8),
                        Text('Tap "Share Link" to invite others',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) =>
                        _buildMessage(_messages[index], theme),
                  ),
          ),

          // Input
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    tooltip: 'Send file (P2P)',
                    onPressed: _pickAndSendFile,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: const Icon(Icons.send),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(ChatMessage msg, ThemeData theme) {
    final isMe = msg.senderId == _userId;
    final isEditing = _editingId == msg.id;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!isMe)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(msg.senderAvatar, style: const TextStyle(fontSize: 20)),
              ),
            Flexible(
              child: GestureDetector(
                onLongPress: isMe && msg.mediaId == null
                    ? () => _showMessageActions(msg)
                    : isMe
                        ? () => _showDeleteAction(msg)
                        : null,
                child: Column(
                  crossAxisAlignment:
                      isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    if (!isMe)
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 2),
                        child: Text(
                          msg.senderName,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (isEditing)
                      _buildEditRow(msg, theme)
                    else
                      Container(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.75,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isMe
                              ? theme.colorScheme.primary
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isMe ? 16 : 4),
                            bottomRight: Radius.circular(isMe ? 4 : 16),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (msg.mediaId != null)
                              _buildMediaContent(msg, isMe, theme)
                            else
                              Text(
                                msg.text,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isMe
                                      ? theme.colorScheme.onPrimary
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                            const SizedBox(height: 4),
                            Text(
                              '${_formatTime(msg.timestamp)}${msg.edited ? ' (edited)' : ''}',
                              style: TextStyle(
                                fontSize: 10,
                                color: isMe
                                    ? theme.colorScheme.onPrimary.withValues(alpha: 0.6)
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (isMe)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(widget.userAvatar, style: const TextStyle(fontSize: 20)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditRow(ChatMessage msg, ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 200,
          child: TextField(
            controller: _editController,
            autofocus: true,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onSubmitted: (_) => _editMessage(msg.id),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          icon: const Icon(Icons.check, size: 18),
          onPressed: () => _editMessage(msg.id),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => setState(() => _editingId = null),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _buildMediaContent(ChatMessage msg, bool isMe, ThemeData theme) {
    final state = _mediaStates[msg.mediaId];
    final isImage = msg.mediaType?.startsWith('image/') ?? false;

    // Has bytes (local preview or received)
    if (state?.bytes != null) {
      if (isImage) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            state!.bytes!,
            fit: BoxFit.contain,
            width: 250,
          ),
        );
      }
      return Text(
        '📎 ${msg.mediaName ?? 'File'} (${_formatSize(msg.mediaSize ?? 0)})\n✅ Received',
        style: TextStyle(
          fontSize: 13,
          color: isMe ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
        ),
      );
    }

    // Loading
    if (state?.loading == true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '📎 ${msg.mediaName ?? 'File'}',
            style: TextStyle(
              fontSize: 13,
              color: isMe ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: (state?.progress ?? 0) / 100),
          const SizedBox(height: 4),
          Text(
            '${state?.progress ?? 0}%',
            style: TextStyle(
              fontSize: 10,
              color: isMe
                  ? theme.colorScheme.onPrimary.withValues(alpha: 0.6)
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    // Error
    if (state?.error != null) {
      return Text(
        '📎 ${msg.mediaName}\n❌ ${state!.error}',
        style: TextStyle(
          fontSize: 13,
          color: isMe ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
        ),
      );
    }

    // Not requested yet (receiver)
    if (msg.senderId != _userId) {
      return GestureDetector(
        onTap: () => _requestMedia(msg),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isMe
                ? theme.colorScheme.onPrimary.withValues(alpha: 0.15)
                : theme.colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download, size: 18,
                  color: isMe ? theme.colorScheme.onPrimary : theme.colorScheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${msg.mediaName} (${_formatSize(msg.mediaSize ?? 0)})',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isMe ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Sender's own media (showing label)
    return Text(
      '📎 ${msg.mediaName ?? 'File'} (${_formatSize(msg.mediaSize ?? 0)})',
      style: TextStyle(
        fontSize: 13,
        color: isMe ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
      ),
    );
  }

  void _showMessageActions(ChatMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _editingId = msg.id;
                  _editController.text = msg.text;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMessage(msg.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteAction(ChatMessage msg) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.delete, color: Colors.red),
          title: const Text('Delete', style: TextStyle(color: Colors.red)),
          onTap: () {
            Navigator.pop(ctx);
            _deleteMessage(msg.id);
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _timer?.cancel();
    _textController.dispose();
    _editController.dispose();
    _scrollController.dispose();
    PeerService.stopHosting();
    super.dispose();
  }
}

class _MediaState {
  final Uint8List? bytes;
  final bool loading;
  final int progress;
  final String? error;

  _MediaState({this.bytes, this.loading = false, this.progress = 0, this.error});
}
