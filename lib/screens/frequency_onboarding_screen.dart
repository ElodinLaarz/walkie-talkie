import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';

/// 3-step onboarding: welcome → permissions → display name.
class FrequencyOnboardingScreen extends StatefulWidget {
  final ValueChanged<String> onDone;
  const FrequencyOnboardingScreen({super.key, required this.onDone});

  @override
  State<FrequencyOnboardingScreen> createState() => _FrequencyOnboardingScreenState();
}

class _FrequencyOnboardingScreenState extends State<FrequencyOnboardingScreen> {
  int _step = 0;
  bool _btGranted = false;
  bool _micGranted = false;
  final TextEditingController _nameCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  bool get _allGranted => _btGranted && _micGranted;

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            FreqChrome(
              left: const FrequencyWordmark(),
              right: [
                Text(
                  '${(_step + 1).toString().padLeft(2, '0')}/03',
                  style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3),
                ),
              ],
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                child: KeyedSubtree(
                  key: ValueKey(_step),
                  child: _buildStep(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    switch (_step) {
      case 0:
        return _Welcome(onNext: () => setState(() => _step = 1));
      case 1:
        return _Permissions(
          btGranted: _btGranted,
          micGranted: _micGranted,
          onBt: () => setState(() => _btGranted = true),
          onMic: () => setState(() => _micGranted = true),
          onContinue: _allGranted ? () => setState(() => _step = 2) : null,
        );
      default:
        return _NamePicker(
          controller: _nameCtrl,
          onContinue: () {
            final n = _nameCtrl.text.trim();
            if (n.isNotEmpty) widget.onDone(n);
          },
        );
    }
  }
}

class _Welcome extends StatelessWidget {
  final VoidCallback onNext;
  const _Welcome({required this.onNext});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(18),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.podcasts_outlined, size: 32, color: c.accentInk),
          ),
          const SizedBox(height: 20),
          Text(
            'Listen and talk together,\noffline.',
            style: Theme.of(context).textTheme.displayLarge,
          ),
          const SizedBox(height: 14),
          Text(
            "Frequency pairs phones over Bluetooth so nearby friends can join the same voice channel and share whatever you're listening to — no internet required for voice.",
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.ink2),
          ),
          const Spacer(),
          PrimaryButton(
            label: 'Get started',
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

class _Permissions extends StatelessWidget {
  final bool btGranted;
  final bool micGranted;
  final VoidCallback onBt;
  final VoidCallback onMic;
  final VoidCallback? onContinue;

  const _Permissions({
    required this.btGranted,
    required this.micGranted,
    required this.onBt,
    required this.onMic,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Text(
            'STEP 2 · PERMISSIONS',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.1,
              color: c.ink3,
            ),
          ),
          const SizedBox(height: 6),
          Text('Two quick permissions.', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            'We need Bluetooth to find nearby phones, and the microphone to share your voice.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.ink2),
          ),
          const SizedBox(height: 24),
          _PermRow(
            icon: Icons.bluetooth,
            title: 'Bluetooth nearby devices',
            desc: 'Discover and connect to phones and headphones',
            granted: btGranted,
            onGrant: onBt,
          ),
          const SizedBox(height: 10),
          _PermRow(
            icon: Icons.mic_none,
            title: 'Microphone',
            desc: 'Send your voice to the frequency',
            granted: micGranted,
            onGrant: onMic,
          ),
          const Spacer(),
          PrimaryButton(
            label: 'Continue',
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: onContinue,
          ),
        ],
      ),
    );
  }
}

class _PermRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  final bool granted;
  final VoidCallback onGrant;
  const _PermRow({
    required this.icon,
    required this.title,
    required this.desc,
    required this.granted,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return FreqCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: granted ? c.accentSoft : c.surface2,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(
              granted ? Icons.check : icon,
              size: 18,
              color: granted ? c.accentInk : c.ink2,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                Text(
                  desc,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: c.ink3,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (granted)
            Text(
              'Allowed',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: c.accent,
                fontWeight: FontWeight.w500,
              ),
            )
          else
            FreqButton(
              label: 'Allow',
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              fontSize: 13,
              onPressed: onGrant,
            ),
        ],
      ),
    );
  }
}

class _NamePicker extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onContinue;
  const _NamePicker({required this.controller, required this.onContinue});

  @override
  State<_NamePicker> createState() => _NamePickerState();
}

class _NamePickerState extends State<_NamePicker> {
  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final name = widget.controller.text.trim();
    final initials = name.isEmpty ? '—' : name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
    final hasName = name.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Text(
            'STEP 3 · YOUR HANDLE',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.1,
              color: c.ink3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'What should people call you?',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            "This shows up to everyone on the same frequency.",
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.ink2),
          ),
          const SizedBox(height: 28),
          FreqCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initials,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.accentInk,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    autofocus: true,
                    maxLength: 20,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (hasName) widget.onContinue();
                    },
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: c.ink,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                      border: InputBorder.none,
                      hintText: 'Your name',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              'You can change this later.',
              style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
            ),
          ),
          const Spacer(),
          PrimaryButton(
            label: 'Find a frequency',
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: hasName ? widget.onContinue : null,
          ),
        ],
      ),
    );
  }
}
