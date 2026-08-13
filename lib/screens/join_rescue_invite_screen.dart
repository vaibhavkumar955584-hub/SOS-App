import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/rescue_invite_controller.dart';

class JoinRescueInviteScreen extends StatefulWidget {
  const JoinRescueInviteScreen({
    super.key,
    required this.invite,
  });

  final RescueInvitePayload invite;

  @override
  State<JoinRescueInviteScreen> createState() => _JoinRescueInviteScreenState();
}

class _JoinRescueInviteScreenState extends State<JoinRescueInviteScreen> {
  final RescueInviteController _controller = RescueInviteController.instance;
  late Future<RescueInvitePreview> _previewFuture;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _previewFuture = _controller.loadInvitePreview(widget.invite);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Join Rescue')),
      body: FutureBuilder<RescueInvitePreview>(
        future: _previewFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final preview = snapshot.data ??
              RescueInvitePreview.invalid(
                'This rescue link is no longer valid.',
              );

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 24,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.emergency_share_rounded,
                            color: Colors.redAccent,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            preview.isValid
                                ? 'Join Active Rescue?'
                                : 'Rescue Invite Unavailable',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      preview.isValid
                          ? 'A trusted helper invited you into an active SOS rescue session.'
                          : (preview.errorMessage ??
                              'This rescue link is no longer valid.'),
                      style: TextStyle(
                        fontSize: 15,
                        color: colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                    if (preview.isValid) ...[
                      const SizedBox(height: 18),
                      _InviteMetaRow(
                        label: 'Invited by',
                        value: preview.inviterName ?? 'SafeRoute Helper',
                      ),
                      _InviteMetaRow(
                        label: 'Current helpers',
                        value: '${preview.responderCount ?? 0}',
                      ),
                      if (preview.expiresAtMs != null)
                        _InviteMetaRow(
                          label: 'Link expires',
                          value: _formatExpiry(preview.expiresAtMs!),
                        ),
                    ],
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: !preview.isValid || _joining
                            ? null
                            : () => _joinRescue(widget.invite),
                        icon: _joining
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.shield),
                        label: Text(
                          _joining ? 'Joining...' : 'Join as Helper',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => Get.back(),
                        child: const Text('Not Now'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _joinRescue(RescueInvitePayload invite) async {
    setState(() {
      _joining = true;
    });

    final result = await _controller.joinInvite(invite);
    if (!mounted) return;

    setState(() {
      _joining = false;
    });

    if (result.success) {
      Get.until((route) => route.isFirst);
      Get.snackbar(
        'Rescue Joined',
        'You are now helping in this SOS session.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    Get.snackbar(
      'Unable to Join',
      result.errorMessage ?? 'This rescue link is no longer valid.',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.redAccent,
      colorText: Colors.white,
    );
  }

  String _formatExpiry(int expiresAtMs) {
    final expiry = DateTime.fromMillisecondsSinceEpoch(expiresAtMs);
    final minutesLeft =
        expiry.difference(DateTime.now()).inMinutes.clamp(0, 9999);
    if (minutesLeft <= 0) {
      return 'Expired';
    }
    if (minutesLeft < 60) {
      return '$minutesLeft min left';
    }
    final hours = (minutesLeft / 60).floor();
    final remainderMinutes = minutesLeft % 60;
    return remainderMinutes == 0
        ? '$hours hr left'
        : '$hours hr ${remainderMinutes} min left';
  }
}

class _InviteMetaRow extends StatelessWidget {
  const _InviteMetaRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
