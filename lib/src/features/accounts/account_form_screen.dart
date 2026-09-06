// Add / edit account form: provider chips + glass sections.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/s3/s3_account.dart';
import '../../core/storage/account_store.dart';
import '../../ui/glass.dart';

class AccountFormScreen extends ConsumerStatefulWidget {
  final String? accountId;
  const AccountFormScreen({super.key, this.accountId});

  @override
  ConsumerState<AccountFormScreen> createState() => _AccountFormState();
}

class _AccountFormState extends ConsumerState<AccountFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late ProviderType _provider;
  late TextEditingController _name;
  late TextEditingController _endpoint;
  late TextEditingController _region;
  late TextEditingController _accessKey;
  late TextEditingController _secretKey;
  late TextEditingController _sessionToken;
  late TextEditingController _port;
  late bool _pathStyle;
  late bool _useSSL;
  bool _obscureSecret = true;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  bool _initialized = false;

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _region.dispose();
    _accessKey.dispose();
    _secretKey.dispose();
    _sessionToken.dispose();
    _port.dispose();
    super.dispose();
  }

  void _initFromAccount(S3Account? existing) {
    if (_initialized) return;
    _initialized = true;
    _provider = existing?.provider ?? ProviderType.aws;
    _name = TextEditingController(text: existing?.name ?? '');
    _endpoint = TextEditingController(text: existing?.endpoint ?? '');
    _region = TextEditingController(
      text: existing?.region ?? _provider.defaultRegion,
    );
    _accessKey = TextEditingController(text: existing?.accessKey ?? '');
    _secretKey = TextEditingController(text: existing?.secretKey ?? '');
    _sessionToken = TextEditingController(text: existing?.sessionToken ?? '');
    _port = TextEditingController(
      text: existing?.port == null ? '' : '${existing!.port}',
    );
    _pathStyle = existing?.usePathStyle ?? _provider.defaultPathStyle;
    _useSSL = existing?.useSSL ?? true;
  }

  ProviderPreset get _preset =>
      ProviderPresets.all.firstWhere((p) => p.type == _provider);

  void _applyPreset(ProviderType p) {
    setState(() {
      _provider = p;
      _region.text = p.defaultRegion;
      _pathStyle = p.defaultPathStyle;
      if (p == ProviderType.aws) {
        _endpoint.text = ProviderPresets.resolveEndpoint(
          p,
          _region.text.isEmpty ? 'us-east-1' : _region.text,
        );
      } else if (p == ProviderType.minio) {
        if (_endpoint.text.isEmpty) _endpoint.text = '192.168.1.10:9000';
        _useSSL = false;
      } else {
        _endpoint.text = '';
      }
    });
  }

  S3Account _buildAccount(String id) {
    return S3Account(
      id: id,
      name: _name.text,
      provider: _provider,
      endpoint: _endpoint.text.trim(),
      region: _region.text.trim().isEmpty
          ? _provider.defaultRegion
          : _region.text.trim(),
      accessKey: _accessKey.text.trim(),
      secretKey: _secretKey.text,
      sessionToken: _sessionToken.text.trim().isEmpty
          ? null
          : _sessionToken.text.trim(),
      usePathStyle: _pathStyle,
      useSSL: _useSSL,
      port: int.tryParse(_port.text.trim()),
    );
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _testResult = null;
      _testOk = false;
    });
    try {
      final draft = _buildAccount(widget.accountId ?? 'draft');
      final count = await ref
          .read(accountStoreProvider.notifier)
          .testConnection(draft);
      setState(() {
        _testOk = true;
        _testResult = 'Connected — $count bucket(s) found.';
      });
    } catch (e) {
      setState(() => _testResult = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final store = ref.read(accountStoreProvider.notifier);
    if (widget.accountId == null) {
      await store.add(
        name: _name.text,
        provider: _provider,
        endpoint: _endpoint.text,
        region: _region.text,
        accessKey: _accessKey.text,
        secretKey: _secretKey.text,
        sessionToken: _sessionToken.text,
        usePathStyle: _pathStyle,
        useSSL: _useSSL,
        port: int.tryParse(_port.text.trim()),
      );
    } else {
      await store.update(_buildAccount(widget.accountId!));
    }
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.accountId == null
        ? null
        : ref.watch(accountByIdProvider(widget.accountId!));
    _initFromAccount(existing);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          widget.accountId == null ? 'Add account' : 'Edit account',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                const SectionLabel('Provider'),
                Glass(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final p in ProviderType.values)
                            ChoiceChip(
                              label: Text(p.label),
                              avatar: ProviderBadge(provider: p, size: 22),
                              selected: _provider == p,
                              onSelected: (_) => _applyPreset(p),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _preset.help,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SectionLabel('Connection'),
                Glass(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                          prefixIcon: Icon(Icons.label_outline_rounded),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _endpoint,
                        decoration: InputDecoration(
                          labelText: 'Endpoint',
                          hintText: _preset.hint,
                          prefixIcon: const Icon(Icons.dns_outlined),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _region,
                              decoration: const InputDecoration(
                                labelText: 'Region',
                              ),
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'Required'
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _port,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Port (optional)',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SectionLabel('Credentials'),
                Glass(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _accessKey,
                        decoration: const InputDecoration(
                          labelText: 'Access key',
                          prefixIcon: Icon(Icons.key_outlined),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _secretKey,
                        obscureText: _obscureSecret,
                        decoration: InputDecoration(
                          labelText: 'Secret key',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscureSecret
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: () => setState(
                              () => _obscureSecret = !_obscureSecret,
                            ),
                          ),
                        ),
                        validator: (v) =>
                            (v == null || v.isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _sessionToken,
                        decoration: const InputDecoration(
                          labelText: 'Session token (optional, STS)',
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionLabel('Options'),
                Glass(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('Path-style addressing'),
                        subtitle: const Text('Required for MinIO/R2/IP hosts.'),
                        value: _pathStyle,
                        onChanged: (v) => setState(() => _pathStyle = v),
                      ),
                      SwitchListTile(
                        title: const Text('Use SSL (https)'),
                        subtitle: const Text(
                          'Disable for plain-HTTP dev servers.',
                        ),
                        value: _useSSL,
                        onChanged: (v) => setState(() => _useSSL = v),
                      ),
                    ],
                  ),
                ),
                if (_testResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Glass(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            _testOk
                                ? Icons.check_circle_rounded
                                : Icons.error_outline_rounded,
                            color: _testOk ? Colors.green : Colors.red,
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_testResult!)),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: GlowButton(
                        label: 'Test',
                        icon: Icons.bolt_outlined,
                        filled: false,
                        onPressed: _testing ? null : _test,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GlowButton(
                        label: 'Save',
                        icon: Icons.check_rounded,
                        onPressed: _save,
                      ),
                    ),
                  ],
                ),
                if (_testing)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
