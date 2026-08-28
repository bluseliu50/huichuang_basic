import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../auth/auth_controller.dart';
import '../../store/app_state.dart';
import '../../stream/proxy.dart';
import '../login/login_card.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _biometricsAvailable = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    context.read<AuthController>().biometricsAvailable().then((v) {
      if (mounted) setState(() => _biometricsAvailable = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final app = context.watch<AppController>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _AccountCard(auth: auth),
          const _Section('安全'),
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('生物识别保护凭证'),
            subtitle: Text(
              !auth.vaultAvailable
                  ? '当前系统没有可用的安全存储，无法保存密码；登录状态将以本地缓存保留'
                  : _biometricsAvailable
                  ? '仅在需要读取已保存密码时要求验证，启动时不询问'
                  : '未检测到指纹／面容等生物识别支持，保护暂不可用',
            ),
            value: auth.biometricProtect,
            // Grayed out and forced off when either the biometric
            // hardware or secure storage is missing — never hidden, so
            // the state is discoverable.
            onChanged: _biometricsAvailable
                ? (v) => auth.biometricProtect = v
                : null,
          ),
          const _Section('播放'),
          SwitchListTile(
            secondary: const Icon(Icons.memory_outlined),
            title: const Text('硬件解码'),
            subtitle: const Text('遇到花屏时可尝试关闭'),
            value: app.hwDecode,
            onChanged: (v) => app.setHwDecode(v),
          ),
          const _Section('存储'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('清除缓存'),
            subtitle: const Text('清空密钥缓存与临时下载文件'),
            trailing: _clearing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _clearing ? null : () => _clearCache(context),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('清空观看历史'),
            onTap: () => app.clearHistory(),
          ),
          const _Section('关于'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('惠窗中小学端'),
            // Live from the build metadata (pubspec version) — a hardcoded
            // string drifted from the actual release.
            subtitle: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              initialData: null,
              builder: (context, snap) {
                final v = snap.data?.version;
                return Text('版本 ${v ?? '…'} · 非官方第三方客户端 · CC BY-NC-SA 4.0');
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('法律声明'),
            onTap: () => showLegalDialog(context),
          ),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('项目主页'),
            subtitle: const Text('github.com/bluseliu50/huichuang_basic'),
            onTap: () => launchHome(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _clearCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _clearing = true);
    try {
      context.read<StreamProxy>().clearCaches();
      final app = context.read<AppController>();
      await app.clearTempDownloads();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
    messenger.showSnackBar(const SnackBar(content: Text('缓存已清除')));
  }

  Future<void> launchHome() async {
    await launchUrl(
      Uri.parse('https://github.com/bluseliu50/huichuang_basic'),
      mode: LaunchMode.externalApplication,
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final logged = auth.isLoggedIn || auth.status == AuthStatus.needsRelogin;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(
                Icons.person_outline,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    logged
                        ? (auth.user?.name ?? auth.savedAccount ?? '已登录')
                        : '未登录',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (logged && auth.token != null)
                    Text(
                      '有效期至 ${_fmtDate(auth.token!.expiresAt)}（自动续期）',
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                ],
              ),
            ),
            logged
                ? TextButton(
                    onPressed: () => _logout(context),
                    child: const Text('退出登录'),
                  )
                : FilledButton.tonal(
                    onPressed: () => showLoginCard(context),
                    child: const Text('登录'),
                  ),
          ],
        ),
      ),
    );
  }

  String _fmtDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _logout(BuildContext context) async {
    final auth = context.read<AuthController>();
    final wipe = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('是否同时删除已保存的账号密码？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('仅退出'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除并退出'),
          ),
        ],
      ),
    );
    if (wipe != null) {
      await auth.logout(wipeCredentials: wipe);
    }
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

Future<void> showLegalDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('法律声明'),
      content: const SingleChildScrollView(
        child: Text(
          '1. 惠窗中小学端是非官方第三方客户端，与教育部、中央电化教育馆及国家中小学智慧教育平台无任何隶属或合作关系。\n\n'
          '2. 平台全部课程、教材及其它资源的版权归原权利人所有。本应用不存储、不分发任何平台内容，仅在你本人登录后以你自己的账号访问官方接口。\n\n'
          '3. 本应用未破解任何加密或访问控制：视频解密密钥均通过平台官方接口、使用你自己的有效登录凭证获取。\n\n'
          '4. 仅供个人学习使用，严禁将本应用或其获取的资源用于商业用途或二次分发。\n\n'
          '5. 使用本应用产生的任何后果由使用者自行承担。若相关方认为本应用侵犯其权益，可通过项目仓库提出，我们将及时处理。\n\n'
          '6. 本应用以 CC BY-NC-SA 4.0 协议开源。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('我知道了'),
        ),
      ],
    ),
  );
}
