import 'package:flutter_test/flutter_test.dart';
import 'package:guest_chat/main.dart';

void main() {
  testWidgets('App starts', (WidgetTester tester) async {
    await tester.pumpWidget(const GuestChatApp());
    expect(find.text('Guest Chat'), findsWidgets);
  });
}
