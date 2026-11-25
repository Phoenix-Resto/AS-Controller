import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:as_controller/main.dart';

void main() {
  testWidgets('shows pairing fields', (tester) async {
    await tester.pumpWidget(const AsControllerApp());
    expect(find.text('AS Controller · Keyboard Mode'), findsOneWidget);
    expect(find.text('Connect to PC'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
  });
}
