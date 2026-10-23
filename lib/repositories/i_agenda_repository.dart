import 'package:flutter/foundation.dart';
import '../models/agenda_event.dart';

enum AgendaFilterStatus {
  all,
  upcoming,
  past,
  synced,
  unsynced,
}

/// 日程数据仓储抽象契约接口 (SSOT)
abstract class IAgendaRepository {
  List<AgendaEvent> get allEvents;
  ValueListenable<List<AgendaEvent>> get eventsNotifier;

  Future<void> init();
  Future<void> addEvent(AgendaEvent event);
  Future<void> addEvents(List<AgendaEvent> events);
  Future<void> removeEvent(String id);
  Future<void> clearAll();
  Future<void> updateEvent(AgendaEvent event);
  Future<void> markAsSynced(String id);
  Future<List<AgendaEvent>> mergeRemoteEvents(List<AgendaEvent> remote);

  List<AgendaEvent> filter({
    String query = '',
    AgendaFilterStatus status = AgendaFilterStatus.all,
  });

  String exportAllToIcs();
}
