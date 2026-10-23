import 'package:flutter/material.dart';
import '../repositories/agenda_repository.dart';

/// 日程列表搜索与分类筛选栏
class AgendaFilterBar extends StatefulWidget {
  final AgendaFilterStatus currentFilter;
  final ValueChanged<AgendaFilterStatus> onFilterChanged;
  final ValueChanged<String> onSearchChanged;
  final Map<AgendaFilterStatus, int>? counts;

  const AgendaFilterBar({
    super.key,
    required this.currentFilter,
    required this.onFilterChanged,
    required this.onSearchChanged,
    this.counts,
  });

  @override
  State<AgendaFilterBar> createState() => _AgendaFilterBarState();
}

class _AgendaFilterBarState extends State<AgendaFilterBar> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 搜索栏
        TextField(
          controller: _searchController,
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF0F172A),
            fontSize: 13.5,
          ),
          decoration: InputDecoration(
            hintText: '搜索日程标题、地点或备忘事项...',
            hintStyle: TextStyle(
              color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
            ),
            prefixIcon: Icon(
              Icons.search,
              size: 20,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: Icon(
                      Icons.clear,
                      size: 18,
                      color: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF64748B),
                    ),
                    onPressed: () {
                      _searchController.clear();
                      widget.onSearchChanged('');
                      setState(() {});
                    },
                  )
                : null,
            filled: true,
            fillColor:
                isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? const Color(0xFF334155)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? const Color(0xFF334155)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? const Color(0xFF60A5FA)
                    : const Color(0xFF2563EB),
                width: 1.5,
              ),
            ),
          ),
          onChanged: (val) {
            widget.onSearchChanged(val);
            setState(() {});
          },
        ),
        const SizedBox(height: 10),

        // 筛选 Chip 滚动条
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildChip(
                label: '全部',
                status: AgendaFilterStatus.all,
                count: widget.counts?[AgendaFilterStatus.all],
                isDark: isDark,
              ),
              const SizedBox(width: 8),
              _buildChip(
                label: '未来待办',
                status: AgendaFilterStatus.upcoming,
                count: widget.counts?[AgendaFilterStatus.upcoming],
                isDark: isDark,
              ),
              const SizedBox(width: 8),
              _buildChip(
                label: '已同步日历',
                status: AgendaFilterStatus.synced,
                count: widget.counts?[AgendaFilterStatus.synced],
                isDark: isDark,
              ),
              const SizedBox(width: 8),
              _buildChip(
                label: '未写入日历',
                status: AgendaFilterStatus.unsynced,
                count: widget.counts?[AgendaFilterStatus.unsynced],
                isDark: isDark,
              ),
              const SizedBox(width: 8),
              _buildChip(
                label: '历史过期',
                status: AgendaFilterStatus.past,
                count: widget.counts?[AgendaFilterStatus.past],
                isDark: isDark,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChip({
    required String label,
    required AgendaFilterStatus status,
    int? count,
    bool isDark = false,
  }) {
    final isSelected = widget.currentFilter == status;
    final countText = count != null ? ' ($count)' : '';

    return FilterChip(
      selected: isSelected,
      label: Text('$label$countText'),
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        color: isSelected
            ? (isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8))
            : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569)),
      ),
      backgroundColor:
          isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
      selectedColor:
          isDark ? const Color(0xFF1E3A8A) : const Color(0xFFDBEAFE),
      checkmarkColor:
          isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8),
      side: BorderSide(
        color: isSelected
            ? (isDark ? const Color(0xFF3B82F6) : const Color(0xFF93C5FD))
            : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onSelected: (_) => widget.onFilterChanged(status),
    );
  }
}
