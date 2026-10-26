import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anno2agenda/models/agenda_event.dart';
import 'package:anno2agenda/widgets/agenda_event_card.dart';

void main() {
  testWidgets(
      'AgendaEventCard displays date when showDate is true and hides when false',
      (tester) async {
    final event = AgendaEvent(
      id: 'test_1',
      title: '高等数学讲座',
      startTime: DateTime(2026, 10, 25, 10, 0),
      endTime: DateTime(2026, 10, 25, 11, 30),
      location: '理科楼 A101',
      description: '复习微积分',
      sourceText: '',
      checklist: ['带笔记本'],
    );

    // 1. showDate: true
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgendaEventCard(
            event: event,
            showDate: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('10月25日'), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('11:30'), findsOneWidget);
    expect(find.text('高等数学讲座'), findsOneWidget);
    expect(find.text('理科楼 A101'), findsOneWidget);
    expect(find.text('复习微积分'), findsOneWidget);
    expect(find.text('带笔记本'), findsOneWidget);

    // 2. showDate: false
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgendaEventCard(
            event: event,
            showDate: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('10月25日'), findsNothing);
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('11:30'), findsOneWidget);
  });

  testWidgets('AgendaEventCard title inline editing', (tester) async {
    AgendaEvent current = AgendaEvent(
      id: 'test_2',
      title: '旧标题',
      startTime: DateTime(2026, 10, 25, 14, 0),
      endTime: DateTime(2026, 10, 25, 15, 0),
      sourceText: '',
    );
    AgendaEvent? updatedEvent;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgendaEventCard(
            event: current,
            onEventChanged: (e) => updatedEvent = e,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点击标题进入就地编辑态
    await tester.tap(find.text('旧标题'));
    await tester.pumpAndSettle();

    // 应该出现 TextField
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '新标题修改');
    await tester.pumpAndSettle();

    // 点击保存按钮
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(find.text('新标题修改'), findsOneWidget);
    expect(updatedEvent?.title, '新标题修改');
  });

  testWidgets('AgendaEventCard location and description inline editing',
      (tester) async {
    AgendaEvent current = AgendaEvent(
      id: 'test_3',
      title: '会议',
      startTime: DateTime(2026, 10, 25, 14, 0),
      endTime: DateTime(2026, 10, 25, 15, 0),
      location: '旧地点',
      description: '旧描述',
      sourceText: '',
    );
    AgendaEvent? updatedEvent;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgendaEventCard(
            event: current,
            onEventChanged: (e) => updatedEvent = e,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 编辑地点
    await tester.tap(find.text('旧地点'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '腾讯会议：123-456');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(find.text('腾讯会议：123-456'), findsOneWidget);
    expect(updatedEvent?.location, '腾讯会议：123-456');

    // 2. 编辑描述
    await tester.tap(find.text('旧描述'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '新描述更新');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(find.text('新描述更新'), findsOneWidget);
    expect(updatedEvent?.description, '新描述更新');
  });

  testWidgets('AgendaEventCard checklist add, edit, and remove', (tester) async {
    AgendaEvent current = AgendaEvent(
      id: 'test_4',
      title: '事项',
      startTime: DateTime(2026, 10, 25, 14, 0),
      endTime: DateTime(2026, 10, 25, 15, 0),
      sourceText: '',
      checklist: ['事项A'],
    );
    AgendaEvent? updatedEvent;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgendaEventCard(
            event: current,
            onEventChanged: (e) => updatedEvent = e,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('事项A'), findsOneWidget);

    // 1. 添加待办事项
    await tester.tap(find.text('添加待办'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '事项B');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check).first);
    await tester.pumpAndSettle();

    expect(find.text('事项B'), findsOneWidget);
    expect(updatedEvent?.checklist, containsAll(['事项A', '事项B']));

    // 2. 删除待办事项
    final closeIcons = find.byIcon(Icons.close);
    await tester.tap(closeIcons.first);
    await tester.pumpAndSettle();

    expect(find.text('事项A'), findsNothing);
  });

  testWidgets('AgendaEventCard delete button calls onDelete', (tester) async {
    bool deleted = false;
    final event = AgendaEvent(
      id: 'test_5',
      title: '待删事项',
      startTime: DateTime(2026, 10, 25, 10, 0),
      endTime: DateTime(2026, 10, 25, 11, 0),
      sourceText: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgendaEventCard(
            event: event,
            onDelete: () => deleted = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(deleted, isTrue);
  });

  testWidgets('AgendaEventCard pick date and time triggers pickers',
      (tester) async {
    final event = AgendaEvent(
      id: 'test_6',
      title: '测试时间选择',
      startTime: DateTime(2026, 10, 25, 10, 0),
      endTime: DateTime(2026, 10, 25, 11, 0),
      sourceText: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgendaEventCard(
            event: event,
            showDate: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点击日期胶囊，应弹出 DatePicker 对话框
    await tester.tap(find.textContaining('10月25日'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);

    // 关闭对话框（支持中文或英文环境 Cancel / 取消）
    final cancelBtn = find.text('Cancel').evaluate().isNotEmpty
        ? find.text('Cancel')
        : find.text('取消');
    await tester.tap(cancelBtn);
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);

    // 点击开始时间胶囊，应弹出 TimePicker 对话框
    await tester.tap(find.text('10:00'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);

    // 关闭对话框
    final cancelTimeBtn = find.text('Cancel').evaluate().isNotEmpty
        ? find.text('Cancel')
        : find.text('取消');
    await tester.tap(cancelTimeBtn);
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
  });
}
