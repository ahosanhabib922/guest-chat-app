import 'package:flutter/material.dart';
import '../services/chat_service.dart';
import '../services/crypto_service.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _nameController = TextEditingController();
  final _joinLinkController = TextEditingController();
  String _avatar = avatars[0];
  int _ttl = 60;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // Clean up expired rooms on every home screen visit
    ChatService.cleanupExpiredRooms();
  }

  Future<void> _startChat() async {
    if (_nameController.text.trim().isEmpty) {
      _showError('Please enter your name.');
      return;
    }
    setState(() => _loading = true);
    try {
      await ChatService.getAnonymousUser();
      final code = ChatService.generateRoomCode();
      final key = CryptoService.generateKey();
      await ChatService.createRoom(code, _ttl);

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            roomId: code,
            encryptionKey: key,
            userName: _nameController.text.trim(),
            userAvatar: _avatar,
          ),
        ),
      );
    } catch (e) {
      _showError('Failed to create chat room.');
      setState(() => _loading = false);
    }
  }

  Future<void> _joinChat() async {
    if (_nameController.text.trim().isEmpty) {
      _showError('Please enter your name.');
      return;
    }

    final parsed = _parseJoinLink(_joinLinkController.text);
    if (parsed == null) {
      _showError('Invalid link. Paste the full invite link.');
      return;
    }

    setState(() => _loading = true);
    try {
      await ChatService.getAnonymousUser();

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            roomId: parsed['code']!,
            encryptionKey: parsed['key']!,
            userName: _nameController.text.trim(),
            userAvatar: _avatar,
          ),
        ),
      );
    } catch (e) {
      _showError('Failed to join chat.');
      setState(() => _loading = false);
    }
  }

  Map<String, String>? _parseJoinLink(String input) {
    final trimmed = input.trim();
    final match = RegExp(r'/chat/([A-Z0-9]{6})#(.+)$', caseSensitive: false)
        .firstMatch(trimmed);
    if (match != null) {
      return {'code': match.group(1)!.toUpperCase(), 'key': match.group(2)!};
    }
    return null;
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            children: [
              // Header
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Center(
                  child: Text('💬', style: TextStyle(fontSize: 32)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Guest Chat',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'End-to-end encrypted. No account. No trace.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),

              // Profile
              _buildCard(
                theme,
                title: 'Your Profile',
                subtitle: 'Choose a name and avatar for this session.',
                child: Column(
                  children: [
                    TextField(
                      controller: _nameController,
                      maxLength: 20,
                      decoration: const InputDecoration(
                        hintText: 'Enter your name...',
                        counterText: '',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: avatars.map((a) {
                        final selected = a == _avatar;
                        return GestureDetector(
                          onTap: () => setState(() => _avatar = a),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: selected
                                  ? theme.colorScheme.primaryContainer
                                  : theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                              border: selected
                                  ? Border.all(
                                      color: theme.colorScheme.primary,
                                      width: 2,
                                    )
                                  : null,
                            ),
                            child: Center(
                              child: Text(a, style: const TextStyle(fontSize: 22)),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Start Chat
              _buildCard(
                theme,
                title: 'Start a New Chat',
                subtitle: 'Create an encrypted room. Set how long it lasts.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Auto-delete after',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ttlOptions.map((opt) {
                        final selected = opt['value'] == _ttl;
                        return ChoiceChip(
                          label: Text(opt['label'] as String),
                          selected: selected,
                          onSelected: (_) =>
                              setState(() => _ttl = opt['value'] as int),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _loading ? null : _startChat,
                        child: Text(_loading ? 'Creating...' : 'Start Chat'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Join Chat
              _buildCard(
                theme,
                title: 'Join a Chat',
                subtitle: 'Paste the invite link from the host.',
                child: Column(
                  children: [
                    TextField(
                      controller: _joinLinkController,
                      decoration: const InputDecoration(
                        hintText: 'Paste invite link here...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonal(
                        onPressed: _loading ? null : _joinChat,
                        child: const Text('Join'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Footer
              Text(
                '🔒 End-to-end encrypted. Messages auto-delete.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(
    ThemeData theme, {
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 4),
            Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _joinLinkController.dispose();
    super.dispose();
  }
}
