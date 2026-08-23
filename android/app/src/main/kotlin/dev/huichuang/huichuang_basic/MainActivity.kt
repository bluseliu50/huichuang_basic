package dev.huichuang.huichuang_basic

import io.flutter.embedding.android.FlutterFragmentActivity

// local_auth's BiometricPrompt requires a FragmentActivity host; a plain
// FlutterActivity throws no_fragment_activity (swallowed as auth failure).
class MainActivity : FlutterFragmentActivity()
