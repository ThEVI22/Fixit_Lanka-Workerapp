import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../widgets/custom_dialog.dart'; // ✅ Import CustomDialog

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  String _workerId = "";
  String _workerDocId = "";
  String _workerEmail = ""; // ✅ Added Email
  int _clearedTimestamp = 0; // ✅ Filter: Cleared Time
  bool _isLoading = true;
  bool _hasVisibleNotifications = false; // ✅ Track visibility for validation

  @override
  void initState() {
    super.initState();
    _loadWorkerInfo();
  }

  Future<void> _loadWorkerInfo() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _workerId = prefs.getString('worker_id') ?? ""; // Staff ID (W-123)
      _workerDocId = prefs.getString('worker_doc_id') ?? ""; // Doc ID (Auto)
      _workerEmail = prefs.getString('worker_email') ?? ""; // ✅ Load Email
      _clearedTimestamp = prefs.getInt('cleared_timestamp') ?? 0; // ✅ Load Filter
      _isLoading = false;
    });
    
    // Update Last Seen Timestamp immediately
    _updateLastSeen();
  }

  Future<void> _updateLastSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_seen_notification_ts', DateTime.now().millisecondsSinceEpoch);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: Text("Notifications", style: GoogleFonts.outfit(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 18)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.black, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
            tooltip: "Clear All",
            onPressed: _showClearDialog,
          )
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: Colors.black))
        : StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('notifications')
                // ✅ RAW QUERY: Now including Email Address to match Supervisor "Verify" actions
                .where('target', whereIn: ['worker', _workerId, _workerDocId, _workerEmail].where((s) => s.isNotEmpty).toList())
                .snapshots(),
            builder: (context, snapshot) {
              // 🔍 DEBUG LOG: Query Params
              if (_isLoading) {
                 print("🔍 DEBUG: Notification Query Params -> ID: $_workerId, DocId: $_workerDocId, Email: $_workerEmail");
              }

              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator(color: Colors.black));
              }

              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                 // ✅ Update state for validation
                 WidgetsBinding.instance.addPostFrameCallback((_) {
                   if(_hasVisibleNotifications) setState(() => _hasVisibleNotifications = false);
                 });
                 return _buildEmptyState();
              }

              final docs = snapshot.data!.docs;
              print("🔍 DEBUG: Received ${docs.length} raw notifications from Firestore.");
              
              // Sort locally (Newest First)
              docs.sort((a, b) {
                Timestamp? tA = (a.data() as Map<String, dynamic>)['timestamp'];
                Timestamp? tB = (b.data() as Map<String, dynamic>)['timestamp'];
                if (tA == null) return 1;
                if (tB == null) return -1;
                return tB.compareTo(tA);
              });
              
              // ✅ Check if any are visible after filter
              bool hasContent = docs.any((d) {
                 final ts = (d.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
                 return ts == null || ts.millisecondsSinceEpoch > _clearedTimestamp;
              });

              WidgetsBinding.instance.addPostFrameCallback((_) {
                 if(_hasVisibleNotifications != hasContent) setState(() => _hasVisibleNotifications = hasContent);
                 _updateLastSeen();
              });

              if (!hasContent) return _buildEmptyState();

              return ListView.separated(
                padding: const EdgeInsets.all(20),
                itemCount: docs.length,
                separatorBuilder: (_,__) => const SizedBox(height: 12),
                itemBuilder: (ctx, i) {
                  final data = docs[i].data() as Map<String, dynamic>;
                  final ts = data['timestamp'] as Timestamp?;

                  final title = data['title'] as String? ?? "";
                  print("🔍 DEBUG Check Doc [${docs[i].id}]: Title='$title', Target='${data['target']}'");

                  // ✅ CLIENT-SIDE CLEAR FILTER:
                  if (ts != null && ts.millisecondsSinceEpoch <= _clearedTimestamp) {
                    print("   -> HIDDEN (Cleared)");
                    return const SizedBox.shrink(); // Hide efficiently
                  }

                  // ✅ BLOCK FILTER: Hide Self-Reports (User Request)
                  if (title == "Report Sent") {
                     print("   -> HIDDEN (Blocklist: Report Sent)");
                     return const SizedBox.shrink();
                  }
                  if (title == "Issue Reported") {
                     print("   -> HIDDEN (Blocklist: Issue Reported)");
                     return const SizedBox.shrink();
                  }
                  if (title.contains("Team Update")) {
                     print("   -> HIDDEN (Blocklist: Team Update)");
                     return const SizedBox.shrink();
                  }
                  
                  print("   -> VISIBLE");
                  return _buildNotificationCard(data);
                },
              );
            },
        ),
    );
  }

  void _showClearDialog() {
    // ✅ VALIDATION: Empty Check
    if (!_hasVisibleNotifications) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("No notifications to clear", style: GoogleFonts.outfit(color: Colors.white)),
          backgroundColor: Colors.grey[800],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 2),
        )
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => CustomDialog(
        icon: Icons.delete_sweep_rounded,
        iconColor: Colors.red,
        iconContainerColor: Colors.red.withOpacity(0.1),
        title: "Clear Notifications?",
        subtitle: "This will only hide these notifications from your view. It does not delete them permanently.",
        primaryActionText: "Clear All",
        primaryColor: Colors.red,
        onPrimaryAction: () async {
          Navigator.pop(ctx);
          // Update cleared timestamp
          final prefs = await SharedPreferences.getInstance();
          final now = DateTime.now().millisecondsSinceEpoch;
          await prefs.setInt('cleared_timestamp', now);
          
          if (mounted) {
            setState(() {
              _clearedTimestamp = now; 
              _hasVisibleNotifications = false; // ✅ Instant update
            });
          }
        },
        secondaryActionText: "Cancel",
        onSecondaryAction: () => Navigator.pop(ctx),
      )
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
           Container(
             padding: const EdgeInsets.all(20),
             decoration: BoxDecoration(color: Colors.grey[50], shape: BoxShape.circle),
             child: Icon(Icons.notifications_off_outlined, size: 40, color: Colors.grey[400]),
           ),
           const SizedBox(height: 16),
           Text("No Notifications", style: GoogleFonts.outfit(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold)), // ✅ Updated Style
           const SizedBox(height: 8),
           Text("You're all caught up!", style: GoogleFonts.outfit(color: Colors.grey[500], fontSize: 14)), // ✅ Added Subtext
        ],
      ),
    );
  }

  Widget _buildNotificationCard(Map<String, dynamic> data) {
    // 1. Check for "Cleared" status locally
    // (We are skipping this for now to ensure MAXIMUM VISIBILITY as per user request. 
    // If they press clear, nothing happens? That's safer than accidental hiding right now.)
    
    final String title = data['title'] ?? "Notification";
    final String message = data['message'] ?? (data['body'] ?? "");
    final String type = data['type'] ?? "info";
    final Timestamp? ts = data['timestamp'];

    IconData icon;
    Color color;
    Color bgColor;

    // --- FLAT MAPPING (Raw & Simple) ---
    
    if (type == 'assignment' || title.contains("Assign")) {
       icon = Icons.work_outline_rounded;
       color = Colors.blue[700]!;
       bgColor = Colors.blue[50]!;
    }
    else if (type == 'worker_removed' || type == 'worker_replaced' || title.contains("Replaced") || title.contains("Removed")) {
       icon = Icons.person_remove_rounded;
       color = Colors.red[700]!;
       bgColor = Colors.red[50]!;
    }
    else if (type == 'team_update' || title.contains("Team")) {
       icon = Icons.group_outlined;
       color = Colors.indigo[700]!;
       bgColor = Colors.indigo[50]!;
    }
    else if (type == 'sick_report' || title.contains("Sick")) {
       // Check Verified Status
       if (title.contains("Verified")) {
         icon = Icons.check_circle_outline_rounded;
         color = Colors.green[700]!;
         bgColor = Colors.green[50]!;
       } else if (title.contains("Declined")) {
         icon = Icons.cancel_outlined;
         color = Colors.red[700]!;
         bgColor = Colors.red[50]!;
       } else {
         icon = Icons.sick_outlined; // Self-report
         color = Colors.orange[700]!;
         bgColor = Colors.orange[50]!;
       }
    }
    else if (title.contains("Issue") || type == 'site_issue') {
       if (title.contains("Verified")) {
         icon = Icons.check_circle_outline_rounded;
         color = Colors.green[700]!;
         bgColor = Colors.green[50]!;
       } else if (title.contains("Declined")) {
         icon = Icons.cancel_outlined;
         color = Colors.red[700]!;
         bgColor = Colors.red[50]!;
       } else {
         icon = Icons.report_problem_outlined;
         color = Colors.orange[700]!;
         bgColor = Colors.orange[50]!;
       }
    }
    else if (type == 'alert' || title.contains("Late") || title.contains("Missed")) {
        icon = Icons.warning_amber_rounded;
        color = Colors.orange[800]!;
        bgColor = Colors.orange[50]!;
    }
    else if (title.contains("Resumed")) {
        icon = Icons.play_circle_fill_rounded;
        color = Colors.deepPurple[700]!;
        bgColor = Colors.deepPurple[50]!;
    }
    else if (title.contains("Hold") || title.contains("Paused")) {
        icon = Icons.pause_circle_filled_rounded;
        color = Colors.amber[800]!;
        bgColor = Colors.amber[50]!;
    }
    else if (title.contains("Completed") || type == 'success') {
        icon = Icons.check_circle_rounded;
        color = Colors.green[700]!;
        bgColor = Colors.green[50]!;
    }
    else {
        // Fallback
        icon = Icons.notifications_none_rounded;
        color = Colors.grey[700]!;
        bgColor = Colors.grey[100]!;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(title, style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87))),
                    if (ts != null)
                      Text(_timeAgo(ts.toDate()), style: GoogleFonts.outfit(fontSize: 11, color: Colors.grey[400]))
                  ],
                ),
                const SizedBox(height: 6),
                Text(message, style: GoogleFonts.outfit(fontSize: 13, color: Colors.grey[600], height: 1.4)),
              ],
            ),
          )
        ],
      ),
    );
  }

  String _timeAgo(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inDays > 0) return "${diff.inDays}d ago";
    if (diff.inHours > 0) return "${diff.inHours}h ago";
    if (diff.inMinutes > 0) return "${diff.inMinutes}m ago";
    return "Just now";
  }
}
