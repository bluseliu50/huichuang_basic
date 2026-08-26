// Flutter 3.47 regression: showDialog no longer wraps builder content in an
// implicit Material surface — the login card's TextFields crashed with
// "No Material widget found" (first seen on Android, where no saved account
// means the fields are actually needed). showLoginCard must wrap LoginCard
// in a Dialog (which supplies the Material).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huichuang_basic/src/api/models.dart';
import 'package:huichuang_basic/src/auth/auth_controller.dart';
import 'package:huichuang_basic/src/auth/biometric.dart';
import 'package:huichuang_basic/src/auth/login_service.dart'
    show LoginOutcome;
import 'package:huichuang_basic/src/auth/token_store.dart';
import 'package:huichuang_basic/src/ui/login/login_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('login dialog renders its TextFields with a Material surface',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final auth = AuthController(
      store: TokenStore(MemoryKV()),
      settings: await AppSettings.load(),
      biometrics: FakeBiometricGate(),
      loginPerformer: (a, p) async => LoginOutcome(
          TokenBundle(
              accessToken: 'a',
              refreshToken: 'r',
              userId: 'u',
              macKey: 'm',
              expiresAt:
                  DateTime.now().millisecondsSinceEpoch + 86400000),
          null),
    );
    await auth.init();

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthController>.value(
        value: auth,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => showLoginCard(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('手机号 / 通行证ID'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });
}
