import 'package:flutter/material.dart';
import 'dart:async';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'login_screen.dart';
import '../widgets/custom_dialog.dart';
import 'worker_job_details.dart';
import 'notifications_screen.dart';
import 'package:intl/intl.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // --- STATE VARIABLES ---
  String _workerDocId = "";
  String _staffId = "";
  String _workerName = "Loading...";
  String _workerEmail = "";
  bool _isLoadingProfile = true;
  
  // Notification State
  int _lastSeenTimestamp = 0;
  
  // Job State
  String? _currentReportId;
  
  // Timers
  Timer? _attendanceCheckTimer;

  // --- INIT & DISPOSE ---
  @override
  void initState() {
    super.initState();
    _loadWorkerProfile();
    // Run system checks every minute
    _attendanceCheckTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (_workerDocId.isNotEmpty) _runSystemChecks();
    });
  }

  @override
  void dispose() {
    _attendanceCheckTimer?.cancel();
    super.dispose();
  }

  // --- LOGIC: DATA LOADING ---
  Future<void> _loadWorkerProfile() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _workerDocId = prefs.getString('worker_doc_id') ?? "";
      _staffId = prefs.getString('worker_id') ?? "";
      _workerEmail = prefs.getString('worker_email') ?? "";
      _lastSeenTimestamp = prefs.getInt('last_seen_notification_ts') ?? 0;
    });

    if (_workerDocId.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance.collection('staff').doc(_workerDocId).get();
        if (doc.exists && mounted) {
          final data = doc.data();
          setState(() {
             // Robust Name Check
            _workerName = data?['name'] ?? data?['fullName'] ?? data?['username'] ?? "Worker";
            _currentReportId = data?['currentReportId'];
            _isLoadingProfile = false;
          });
          print("DEBUG: Loaded Profile - Name: $_workerName, Report: $_currentReportId"); 
        }
      } catch (e) {
        print("Error fetching profile: $e");
        setState(() => _isLoadingProfile = false);
      }
      _runSystemChecks();
    } else {
      setState(() => _isLoadingProfile = false);
    }
  }

  // --- LOGIC: SYSTEM CHECKS (Attendance/Deadlines) ---
  Future<void> _runSystemChecks() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final todayStr = "${now.year}-${now.month}-${now.day}";

    // 1. Missed Check-In Alert (After 8:30 AM)
    if (now.hour > 8 || (now.hour == 8 && now.minute > 30)) {
      final key = "alert_missed_checkin_$todayStr";
      if (!prefs.containsKey(key)) {
        // Need to check if they have an active job but NO check-in
        final staffDoc = await FirebaseFirestore.instance.collection('staff').doc(_workerDocId).get();
        final currentReportId = staffDoc.data()?['currentReportId'];
        
        if (currentReportId != null) {
          final docId = _getDailyDocId(_staffId, taskId: currentReportId);
          final doc = await FirebaseFirestore.instance.collection('attendance').doc(docId).get();
          
          if (!doc.exists) {
            await _sendSystemNotification(
              title: "Missed Attendance?",
              message: "It's past 8:30 AM. You are now marked as Late.",
              type: "alert_attendance"
            );
            await prefs.setBool(key, true);
          }
        }
      }
    }

    // 2. Missed Check-Out Alert (After 5:30 PM)
    if (now.hour > 17 || (now.hour == 17 && now.minute > 30)) {
      final key = "alert_missed_checkout_$todayStr";
      if (!prefs.containsKey(key)) {
        final staffDoc = await FirebaseFirestore.instance.collection('staff').doc(_workerDocId).get();
        final currentReportId = staffDoc.data()?['currentReportId'];

        if (currentReportId != null) {
          final docId = _getDailyDocId(_staffId, taskId: currentReportId);
          final doc = await FirebaseFirestore.instance.collection('attendance').doc(docId).get();
          
          if (doc.exists) {
             final data = doc.data();
             if (data != null && data['checkOut'] == null) {
               await _sendSystemNotification(
                  title: "Forgot to Check Out?",
                  message: "Shift ended at 5:00 PM. Please mark your checkout.",
                  type: "alert_attendance"
               );
               await prefs.setBool(key, true);
             }
          }
        }
      }
    }
  }

  Future<String?> _fetchTeamId(String taskId) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('all_reports').doc(taskId).get();
      if (doc.exists) {
        final data = doc.data();
        if (data != null) {
          if (data.containsKey('assignedTeamId')) return data['assignedTeamId'];
          if (data.containsKey('teamId')) return data['teamId'];
        }
      }
    } catch (e) { print("Error fetching teamId: $e"); }
    return null;
  }

  Future<void> _sendSystemNotification({required String title, required String message, required String type}) async {
    await FirebaseFirestore.instance.collection('notifications').add({
      'target': _workerDocId,
      'title': title,
      'message': message,
      'type': type,
      'read': false,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  // --- LOGIC: ATTENDANCE HELPERS ---
  String _getDailyDocId(String workerId, {String? taskId}) {
    final now = DateTime.now();
    final tId = taskId ?? "GLOBAL";
    return "WRK-${workerId}_${tId}_${now.year}-${now.month.toString().padLeft(2,'0')}-${now.day.toString().padLeft(2,'0')}";
  }

  Future<void> _handleAttendance(Map<String, dynamic> task, String taskId, String workerId, String workerName) async {
    final now = DateTime.now();
    final docId = _getDailyDocId(workerId, taskId: taskId);
    
    if(mounted) showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

    try {
      final docSnapshot = await FirebaseFirestore.instance.collection('attendance').doc(docId).get();
      if (!mounted) return;
      Navigator.pop(context);

      if (!docSnapshot.exists) {
        _performCheckIn(docId, taskId, workerId, workerName, now);
      } else {
        final data = docSnapshot.data() as Map<String, dynamic>;
        if (data['checkOut'] == null) {
          await _performCheckOut(docId, now, taskId, workerId, workerName);
        } else {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Shift already completed for today.")));
        }
      }
    } catch (e) {
      if(mounted && Navigator.canPop(context)) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  // --- UI HELPERS ---
  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => CustomDialog(
        icon: Icons.error_outline_rounded,
        iconColor: Colors.red,
        iconContainerColor: Colors.red.withOpacity(0.1),
        title: title,
        subtitle: message,
        primaryActionText: "OK",
        onPrimaryAction: () => Navigator.pop(ctx),
        secondaryActionText: "",
      )
    );
  }

  void _showSuccessDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => CustomDialog(
        icon: Icons.check_circle_rounded,
        iconColor: Colors.green,
        iconContainerColor: Colors.green.withOpacity(0.1),
        title: title,
        subtitle: message,
        primaryActionText: "OK", // Single action for cleaner UI
        onPrimaryAction: () => Navigator.pop(ctx),
        secondaryActionText: "",
      )
    );
  }

  // --- LOGIC: ATTENDANCE HELPERS ---

  Future<void> _performCheckIn(String docId, String taskId, String workerId, String workerName, DateTime now) async {
    // 1. Time Validation: 8:00 AM
    if (now.hour < 8) {
      _showErrorDialog("Too Early", "Shift starts at 8:00 AM.\nPlease wait until then to check in.");
      return;
    }

    // 2. Late Calculation
    String status = "Present";
    String? lateReason;
    if (now.hour > 8 || (now.hour == 8 && now.minute > 30)) {
       status = "Late";
       lateReason = await _showLateReasonDialog();
       if (lateReason == null) return;
    }

    if(mounted) showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.black)));
    
    try {
      // 3. Location Permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if(mounted) {
            Navigator.pop(context);
            _showErrorDialog("Permission Denied", "Location permission is required to check in.");
          }
          return;
        }
      }
      
      // 4. Fetch Job Location & Validate Distance
      final reportDoc = await FirebaseFirestore.instance.collection('all_reports').doc(taskId).get();
      if (!reportDoc.exists) throw "Assigned Job not found.";
      
      final rData = reportDoc.data();
      double? jobLat = rData?['lat'];
      double? jobLng = rData?['lng'];
      
      // Fallback for older data structure
      if (rData != null && rData['location'] is GeoPoint) {
         GeoPoint gp = rData['location'];
         jobLat = gp.latitude;
         jobLng = gp.longitude;
      }

      if (jobLat == null || jobLng == null) throw "Job location missing. Cannot verify site.";

      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      double dist = Geolocator.distanceBetween(position.latitude, position.longitude, jobLat, jobLng);

      if (dist > 200) {
        if(mounted) Navigator.pop(context);
        showDialog(
          context: context,
          builder: (ctx) => CustomDialog(
            icon: Icons.location_off_rounded,
            iconColor: Colors.red,
            iconContainerColor: Colors.red.withOpacity(0.1),
            title: "Location Mismatch",
            subtitle: "You are ${(dist).toInt()}m away from the site.\nYou must be within 200m to check in.",
            primaryActionText: "OK",
            onPrimaryAction: () => Navigator.pop(ctx),
            secondaryActionText: "",
          )
        );
        return;
      }

      final String idToWrite = workerId.isNotEmpty ? workerId : _workerDocId;
      
      await FirebaseFirestore.instance.collection('attendance').doc(docId).set({
        'workerId': idToWrite,
        'taskId': taskId,
        'checkIn': FieldValue.serverTimestamp(),
        'checkOut': null,
        'checkInLocation': GeoPoint(position.latitude, position.longitude),
        'status': status,
        'lateReason': lateReason,
        'timestamp': FieldValue.serverTimestamp(), 
      });

      // Notify Supervisor
      String notifMsg = '$workerName checked in ($status) for Task #${taskId.substring(0, 5)}...';
      if (lateReason != null) notifMsg += "\nReason: $lateReason";
      final teamId = await _fetchTeamId(taskId);

      await FirebaseFirestore.instance.collection('notifications').add({
        'type': 'attendance_in',
        'target': 'supervisor',
        'targetTeamId': teamId,
        'title': 'Attendance: Check-In',
        'reportId': taskId,
        'message': notifMsg,
        'isRead': false,
        'timestamp': FieldValue.serverTimestamp(),
        'metadata': {'taskId': taskId, 'workerId': workerId}
      });
      
      if (!mounted) return;
      Navigator.pop(context);
      _showSuccessDialog(status == "Late" ? "Marked Late" : "Checked In", status == "Late" ? "Attendance marked with reason." : "You are marked PRESENT.");

    } catch (e) {
      if(mounted && Navigator.canPop(context)) Navigator.pop(context);
      _showErrorDialog("Error", e.toString());
    }
  }

  Future<void> _performCheckOut(String docId, DateTime now, String taskId, String workerId, String workerName) async {
    // 1. Time Validation: 5:00 PM (17:00)
    if (now.hour < 17) {
      int hoursLeft = 17 - now.hour;
      _showErrorDialog("Shift Not Over", "Work hours end at 5:00 PM.\nTime remaining: ~$hoursLeft hours.");
      return;
    }

    if(mounted) showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.black)));
    
    try {
      // 2. Fetch Job Location & Validate Distance (Same logic as Check-In)
      final reportDoc = await FirebaseFirestore.instance.collection('all_reports').doc(taskId).get();
      if (!reportDoc.exists) throw "Assigned Job not found.";
      
      final rData = reportDoc.data();
      double? jobLat = rData?['lat'];
      double? jobLng = rData?['lng'];

      if (rData != null && rData['location'] is GeoPoint) {
         GeoPoint gp = rData['location'];
         jobLat = gp.latitude;
         jobLng = gp.longitude;
      }
      
      if (jobLat == null || jobLng == null) throw "Job location missing.";

      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      double dist = Geolocator.distanceBetween(position.latitude, position.longitude, jobLat, jobLng);

      if (dist > 200) {
        if(mounted) Navigator.pop(context);
         showDialog(
          context: context,
          builder: (ctx) => CustomDialog(
            icon: Icons.location_off_rounded,
            iconColor: Colors.red,
            iconContainerColor: Colors.red.withOpacity(0.1),
            title: "Location Mismatch",
            subtitle: "You are ${(dist).toInt()}m away from the site.\nYou must be within 200m to check out.",
            primaryActionText: "OK",
            onPrimaryAction: () => Navigator.pop(ctx),
            secondaryActionText: "",
          )
        );
        return;
      }

      await FirebaseFirestore.instance.collection('attendance').doc(docId).update({
        'checkOut': FieldValue.serverTimestamp(),
        'checkOutLocation': GeoPoint(position.latitude, position.longitude),
        'status': 'Completed', 
      });

      final teamId = await _fetchTeamId(taskId);
      
      await FirebaseFirestore.instance.collection('notifications').add({
        'type': 'attendance_out',
        'target': 'supervisor',
        'targetTeamId': teamId,
        'title': 'Attendance: Check-Out', 
        'reportId': taskId, 
        'message': '$workerName checked out (Shift Completed) for Job #${taskId.substring(0, 5)}.',
        'isRead': false,
        'timestamp': FieldValue.serverTimestamp(),
        'metadata': {'taskId': taskId, 'workerId': workerId}
      });

      if (!mounted) return;
      Navigator.pop(context);
      _showSuccessDialog("Shift Completed", "Checked out successfully. Good job!");

    } catch (e) {
      if(mounted && Navigator.canPop(context)) Navigator.pop(context);
      _showErrorDialog("Error", e.toString());
    }
  }

  Future<String?> _showLateReasonDialog() async {
    final reasonController = TextEditingController();
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
             mainAxisSize: MainAxisSize.min,
             children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.orange.withOpacity(0.06), shape: BoxShape.circle),
                  child: const Icon(Icons.warning_amber_rounded, size: 28, color: Colors.orange),
                ),
                const SizedBox(height: 20),
                Text("You are Late", style: GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.black)),
                const SizedBox(height: 8),
                Text("Reason (Optional if emergency)", textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 13, color: Colors.black54)),
                const SizedBox(height: 20),
                TextField(
                  controller: reasonController,
                  decoration: InputDecoration(
                     hintText: "Enter Reason...",
                     hintStyle: GoogleFonts.poppins(color: Colors.grey[400], fontSize: 13),
                     border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.grey)),
                     enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.grey[200]!)),
                     focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.black)),
                     contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                     filled: true,
                     fillColor: Colors.grey[50]
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                   children: [
                      Expanded(child: OutlinedButton(
                        onPressed: () => Navigator.pop(context), 
                        style: OutlinedButton.styleFrom(
                           side: BorderSide(color: Colors.black.withOpacity(0.12)),
                           padding: const EdgeInsets.symmetric(vertical: 12.5),
                           shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: Text("Cancel", style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 15))
                      )),
                      const SizedBox(width: 12),
                      Expanded(child: ElevatedButton(
                         style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black, 
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                         ),
                         onPressed: () => Navigator.pop(context, reasonController.text.isEmpty ? "No Reason Provided" : reasonController.text),
                         child: Text("Submit", style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15))
                      ))
                   ],
                )
             ],
          ),
        )
      )
    );
  }

  // --- REPORTING LOGIC ---
  void _showReportIssueSelection() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
               Text("Report Issue", style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.bold)),
               const SizedBox(height: 8),
               Text("What type of issue are you facing?", style: GoogleFonts.poppins(color: Colors.grey[600], fontSize: 13)),
               const SizedBox(height: 24),
               
               // OPTION 1: Personal / Sick
               _buildReportOption(
                 icon: Icons.sick_outlined,
                 title: "Personal / Sick",
                 color: Colors.orange,
                 onTap: () {
                   Navigator.pop(context);
                   _showPersonalReportDialog();
                 }
               ),
               const SizedBox(height: 12),
               
               // OPTION 2: Site Issue
               _buildReportOption(
                 icon: Icons.construction,
                 title: "Site / Equipment",
                 color: Colors.blue,
                 onTap: () {
                   Navigator.pop(context);
                   _showSiteReportDialog();
                 }
               ),
               
               const SizedBox(height: 16),
               TextButton(
                 onPressed: () => Navigator.pop(context),
                 child: Text("Cancel", style: GoogleFonts.poppins(color: Colors.grey[600], fontWeight: FontWeight.w600)),
               )
            ],
          ),
        )
      )
    );
  }

  Widget _buildReportOption({required IconData icon, required String title, required Color color, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey[200]!),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))]
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Text(title, style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.black87)),
            const Spacer(),
            Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.grey[300])
          ],
        ),
      ),
    );
  }

  void _showPersonalReportDialog() {
    final reasonController = TextEditingController();
    String selectedChip = "Fever";
    
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header with Back Button
                    // Header with Back Button
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: InkWell(
                            onTap: () {
                              Navigator.pop(context);
                              _showReportIssueSelection();
                            },
                            borderRadius: BorderRadius.circular(50),
                            child: Container(
                               padding: const EdgeInsets.all(8),
                               decoration: BoxDecoration(color: Colors.grey[100], shape: BoxShape.circle),
                               child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Colors.black),
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: Colors.orange[50], shape: BoxShape.circle),
                          child: const Icon(Icons.sick_outlined, size: 32, color: Colors.orange),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text("Personal / Sick", style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.bold)),
                    
                    const SizedBox(height: 20),
                    // Chips for Personal
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: ["Fever", "Injury", "Family Emergency", "Other"].map<Widget>((label) {
                         final isSelected = selectedChip == label;
                         return ChoiceChip(
                           label: Text(label, style: GoogleFonts.poppins(fontSize: 13, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal, color: isSelected ? Colors.white : Colors.black87)),
                           selected: isSelected,
                           onSelected: (v) => setDialogState(() => selectedChip = label),
                           selectedColor: Colors.black,
                           backgroundColor: Colors.white,
                           shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: isSelected ? Colors.transparent : Colors.grey[200]!)), 
                           checkmarkColor: Colors.white,
                           padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                         );
                      }).toList(),
                    ),

                    const SizedBox(height: 24),
                    TextField(
                      controller: reasonController,
                      maxLines: 3,
                      style: GoogleFonts.poppins(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: "Additional details (optional)...",
                        hintStyle: GoogleFonts.poppins(color: Colors.grey[400]),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.grey[200]!)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.grey[200]!)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.black)),
                        filled: true, fillColor: Colors.grey[50]
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black, 
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          padding: const EdgeInsets.symmetric(vertical: 16)
                        ),
                        onPressed: () {
                           String fullMsg = "Personal ($selectedChip): ${reasonController.text}";
                           _submitReport("sick_report", fullMsg, reasonController.text);
                           Navigator.pop(context);
                        },
                        child: Text("Submit Report", style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 15))
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(onPressed: () => Navigator.pop(context), child: Text("Cancel", style: GoogleFonts.poppins(color: Colors.grey[600])))
                  ],
                ),
              ),
            );
          }
        );
      }
    );
  }

  void _showSiteReportDialog() {
    final descController = TextEditingController();
    String selectedChip = "Equipment";
    
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header with Back Button
                    // Header with Back Button
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: InkWell(
                            onTap: () {
                              Navigator.pop(context);
                              _showReportIssueSelection();
                            },
                            borderRadius: BorderRadius.circular(50),
                            child: Container(
                               padding: const EdgeInsets.all(8),
                               decoration: BoxDecoration(color: Colors.grey[100], shape: BoxShape.circle),
                               child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Colors.black),
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: Colors.blue[50], shape: BoxShape.circle),
                          child: const Icon(Icons.construction_rounded, size: 32, color: Colors.blue),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text("Site Issue", style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 20),
                    
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: ["Equipment", "Safety", "Materials", "Other"].map<Widget>((label) {
                         final isSelected = selectedChip == label;
                         return ChoiceChip(
                           label: Text(label, style: GoogleFonts.poppins(fontSize: 13, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal, color: isSelected ? Colors.white : Colors.black87)),
                           selected: isSelected,
                           onSelected: (v) => setDialogState(() => selectedChip = label),
                           selectedColor: Colors.black,
                           backgroundColor: Colors.white,
                           shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: isSelected ? Colors.transparent : Colors.grey[200]!)), 
                           checkmarkColor: Colors.white,
                           padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                         );
                      }).toList(),
                    ),
                    
                    const SizedBox(height: 24),
                    TextField(
                      controller: descController,
                      maxLines: 3,
                      style: GoogleFonts.poppins(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: "Describe the issue...",
                         hintStyle: GoogleFonts.poppins(color: Colors.grey[400]),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.grey[200]!)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.grey[200]!)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.black)),
                        filled: true, fillColor: Colors.grey[50]
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                       width: double.infinity,
                       child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black, 
                          foregroundColor: Colors.white, 
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))
                        ),
                        onPressed: () {
                            String fullMsg = "Site Issue ($selectedChip): ${descController.text}";
                            _submitReport("site_issue", fullMsg, descController.text);
                            Navigator.pop(context);
                        },
                        child: Text("Submit Report", style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 15))
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(onPressed: () => Navigator.pop(context), child: Text("Cancel", style: GoogleFonts.poppins(color: Colors.grey[600])))
                  ],
                ),
              ),
            );
          }
        );
      }
    );
  }

  Future<void> _submitReport(String type, String message, String details) async {
    // Note: details can be empty if generic chip selected, handled by validator if needed.
    // Simplifying check to allow submission with just chip if details optional
    if (message.isEmpty) return; 
    try {
      final teamId = _currentReportId != null ? await _fetchTeamId(_currentReportId!) : null;
      await FirebaseFirestore.instance.collection('notifications').add({
          'type': type, // sick_report or site_issue
          'target': 'supervisor',
          'targetTeamId': teamId,
          'title': type == 'sick_report' ? 'Worker Sick' : 'Site Issue Reported',
          'message': '$_workerName: $message',
          'reportId': _currentReportId, // ✅ Added for Supervisor Validation
          'metadata': {'workerId': _staffId, 'details': details},
          'timestamp': FieldValue.serverTimestamp(),
          'isRead': false
      });
      _showSuccessDialog("Report Sent", "Supervisor has been notified.");
    } catch (e) {
      _showErrorDialog("Error", e.toString());
    }
  }


  
  Future<void> _handleLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if(mounted) Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => LoginScreen()), (route) => false);
  }

  Future<void> _showLogoutConfirmation() async {
    showDialog(
      context: context,
      builder: (ctx) => CustomDialog(
        icon: Icons.logout_rounded,
        iconColor: Colors.red,
        iconContainerColor: Colors.red.withOpacity(0.1),
        title: "Log Out?",
        subtitle: "Are you sure you want to log out of the Worker Portal?",
        primaryActionText: "Log Out",
        primaryColor: Colors.red,
        onPrimaryAction: () async {
          Navigator.pop(ctx); // Close dialog
          await _handleLogout();
        },
        secondaryActionText: "Cancel",
        onSecondaryAction: () => Navigator.pop(ctx),
      )
    );
  }

  // --- BUILD UI ---
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _showLogoutConfirmation();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: _buildAppBar(),
        body: _isLoadingProfile 
            ? const Center(child: CircularProgressIndicator(color: Colors.black))
            : StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance.collection('staff').doc(_workerDocId).snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) return Center(child: Text("Error: ${snapshot.error}"));
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: Colors.black));
  
                  final workerData = snapshot.data!.data() as Map<String, dynamic>?;
                  
                  // Real-time updates
                  _workerName = workerData?['name'] ?? workerData?['fullName'] ?? workerData?['username'] ?? "Worker";
                  _currentReportId = workerData?['currentReportId'];
                  
                  // If ID is cleared (e.g. removed by supervisor), force UI update
                  if (_currentReportId == null) {
                     // Ensure any local state dependent on this is reset if needed
                  }
  
                  return RefreshIndicator(
                    onRefresh: () async { await _loadWorkerProfile(); }, // Keep for manual re-init if needed
                    color: Colors.black,
                    child: ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        _buildHero(),
                        const SizedBox(height: 32),
                        _buildQuickActions(),
                        const SizedBox(height: 32),
                        _buildTaskSection(),
                      ],
                    ),
                  );
                }
              ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      toolbarHeight: 90,
      automaticallyImplyLeading: false,
      flexibleSpace: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
               Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 mainAxisAlignment: MainAxisAlignment.center,
                 children: [
                   Text('WORKER PORTAL', style: GoogleFonts.outfit(color: Colors.grey[500], fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2)),
                   Text(_staffId.isNotEmpty ? _staffId : "Worker", style: GoogleFonts.outfit(color: Colors.black, fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -1)),
                 ],
               ),
               // NOTIFICATION BELL (SUPERVISOR STYLE - BLACK)
               GestureDetector(
                 onTap: () async {
                   await Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsScreen()));
                   final prefs = await SharedPreferences.getInstance();
                   setState(() {
                     _lastSeenTimestamp = prefs.getInt('last_seen_notification_ts') ?? 0;
                   });
                 },
                  child: StreamBuilder<QuerySnapshot>(
                    // ✅ FIXED: Ensure we listen to ALL possible IDs (DocID, StaffID, Email)
                    stream: FirebaseFirestore.instance.collection('notifications')
                         .where('target', whereIn: [
                           'worker', 
                           _staffId, 
                           _workerDocId, 
                           _workerEmail,
                           // Add fallback for potential empty strings by filtering them out in the list construction
                         ].where((s) => s != null && s.isNotEmpty).toList()) 
                         .snapshots(),
                    builder: (context, snapshot) {
                       bool showDot = false;
                       if (snapshot.hasData) {
                          final docs = snapshot.data!.docs.where((d) {
                            final data = d.data() as Map<String, dynamic>;
                            
                            // 1. Hide Self-generated (prevents red dot for your own actions)
                            if (['Report Sent', 'Issue Reported'].contains(data['title'])) return false;
                            
                            // 2. Check Timestamp (Newer than last visit)
                            final ts = (data['timestamp'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
                            return ts > _lastSeenTimestamp;
                          }).toList();
                          showDot = docs.isNotEmpty;
                       }

                       return Stack(
                         clipBehavior: Clip.none,
                         children: [
                           Container(
                             padding: const EdgeInsets.all(10), 
                             decoration: BoxDecoration(
                               color: Colors.black, 
                               borderRadius: BorderRadius.circular(14), 
                             ),
                             child: const Icon(Icons.notifications_none_rounded, color: Colors.white, size: 24),
                           ),
                           if (showDot)
                             Positioned(
                               top: -2, right: -2, 
                               child: Container(
                                 width: 12, height: 12,
                                 decoration: BoxDecoration(
                                   color: const Color(0xFFFF3D00), 
                                   shape: BoxShape.circle,
                                   border: Border.all(color: Colors.white, width: 2)
                                 ),
                               ),
                             )
                         ],
                       );
                    },
                 ),
               )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHero() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF111111), Color(0xFF2d2d2d)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 20, offset: const Offset(0, 10))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
           Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             children: [
                Text("Hello,", style: GoogleFonts.poppins(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text(_workerName, style: GoogleFonts.outfit(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                  child: Row(
                    children: [
                      Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.blueAccent, shape: BoxShape.circle)),
                      const SizedBox(width: 8),
                      Text(_currentReportId != null ? "IN-WORK" : "AVAILABLE", style: GoogleFonts.outfit(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold))
                    ],
                  ),
                )
             ],
           ),
           Container(
             padding: const EdgeInsets.all(12),
             decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), shape: BoxShape.circle),
             child: const Icon(Icons.work_outline_rounded, color: Colors.white54),
           )
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    bool hasActiveJob = _currentReportId != null && _currentReportId!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Quick Actions", style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildActionButton(
                icon: Icons.warning_amber_rounded, 
                label: "Report Issue", 
                color: hasActiveJob ? Colors.red[50]! : Colors.grey[100]!, 
                iconColor: hasActiveJob ? Colors.red : Colors.grey, 
                isEnabled: hasActiveJob,
                onTap: () {
                   if(hasActiveJob) {
                     _showReportIssueSelection();
                   } else {
                     _showErrorDialog("No Active Job", "You need an active job to report issues.");
                   }
                }
              )
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildActionButton(
                icon: Icons.history_edu_rounded,
                label: "Attendance",
                color: hasActiveJob ? Colors.blue[50]! : Colors.grey[100]!,
                iconColor: hasActiveJob ? Colors.blue : Colors.grey,
                isEnabled: hasActiveJob,
                onTap: () {
                  if(hasActiveJob) {
                    _showAttendanceHistory(); 
                  } else {
                    _showErrorDialog("No Active Job", "Attendance history available only for active jobs.");
                  }
                }
              )
            ),
          ],
        )
      ],
    );
  }

  // --- WIDGETS: OLD UI STYLE (BORDERED, POPPINS) ---
  Widget _buildActionButton({required IconData icon, required String label, required Color color, required Color iconColor, required VoidCallback onTap, bool isEnabled = true}) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: isEnabled ? 1.0 : 0.5,
        child: Container(
          height: 80,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.grey[200]!), 
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 10),
              Text(label, style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87)), 
            ],
          ),
        ),
      ),
    );
  }

  void _showAttendanceHistory() {
    if (_currentReportId == null) return;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: const BoxDecoration(
          color: Colors.white, 
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))
        ),
        child: Column(
          children: [
            // Handle Bar
            Center(child: Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10)))),
            
            // Header
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10), 
                        decoration: BoxDecoration(color: const Color(0xFF6C63FF).withOpacity(0.1), shape: BoxShape.circle), 
                        child: const Icon(Icons.history_edu_rounded, color: Color(0xFF6C63FF)) // Purple Icon to match target
                      ),
                      const SizedBox(width: 16),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                         Text("Attendance Log", style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.black)),
                         Text("For $_workerName", style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey[500]))
                      ])
                    ],
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.grey),
                  )
                ],
              ),
            ),
            
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('attendance')
                    .where('taskId', isEqualTo: _currentReportId)
                    .where('workerId', whereIn: [_staffId, _workerDocId].where((s) => s.isNotEmpty).toList())
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: Colors.black));
                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return Center(child: Text("No records yet.", style: GoogleFonts.poppins(color: Colors.grey)));

                  final docs = snapshot.data!.docs;
                  docs.sort((a,b) {
                     Timestamp tA = a['checkIn'] ?? Timestamp.now();
                     Timestamp tB = b['checkIn'] ?? Timestamp.now();
                     return tB.compareTo(tA);
                  });

                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 0),
                    itemCount: docs.length,
                    separatorBuilder: (_,__) => const SizedBox(height: 12),
                    itemBuilder: (ctx, i) {
                      final data = docs[i].data() as Map<String, dynamic>;
                      final checkIn = (data['checkIn'] as Timestamp?)?.toDate();
                      final checkOut = (data['checkOut'] as Timestamp?)?.toDate();
                      final status = data['status'] ?? "Present";
                      
                      final isCompleted = status == 'Completed' || status == 'Present';
                      final isLate = status == 'Late';

                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey[100]!),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))]
                        ),
                        child: Row(
                          children: [
                            // 1. Icon Bubble
                            Container(
                              width: 40, height: 40,
                              decoration: BoxDecoration(
                                color: isLate ? Colors.orange.withOpacity(0.1) : Colors.green.withOpacity(0.1),
                                shape: BoxShape.circle
                              ),
                              child: Icon(
                                isLate ? Icons.access_time_filled_rounded : Icons.check_circle_rounded,
                                color: isLate ? Colors.orange : Colors.green,
                                size: 20
                              ),
                            ),
                            const SizedBox(width: 16),
                            
                            // 2. Details
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(DateFormat('MMM d, yyyy').format(checkIn ?? DateTime.now()), 
                                    style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 14, color: Colors.black)
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Text("IN: ", style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey[400])),
                                      Text(checkIn != null ? DateFormat('hh:mm a').format(checkIn) : '--', style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.black)),
                                      const SizedBox(width: 12),
                                      Text("OUT: ", style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey[400])),
                                      Text(checkOut != null ? DateFormat('hh:mm a').format(checkOut) : '--', style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.black)),
                                    ],
                                  )
                                ],
                              ),
                            ),
                            
                            // 3. Badge (Optional, but kept for clarity)
                            /*
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: isLate ? Colors.orange[50] : Colors.green[50], 
                                borderRadius: BorderRadius.circular(6)
                              ),
                              child: Text(status, style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w600, color: isLate ? Colors.orange : Colors.green))
                            )
                            */
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildTaskSection() {
     return Column(
       crossAxisAlignment: CrossAxisAlignment.start,
       children: [
         Row(
           mainAxisAlignment: MainAxisAlignment.spaceBetween,
           children: [
             Text("My Assignment", style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
           ],
         ),
         const SizedBox(height: 16),
         _buildTaskStream(),
       ],
     );
  }

  Widget _buildTaskStream() {
    // STRATEGY 1: Use ID from Profile (Most Reliable)
    if (_currentReportId != null && _currentReportId!.isNotEmpty) {
      return StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('all_reports').doc(_currentReportId).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || !snapshot.data!.exists) {
             // Profile says we have work, but report missing?
             // Fallback to query just in case ID is stale
             return _buildQueryTaskStream();
          }
          final data = snapshot.data!.data() as Map<String, dynamic>;
          // Safety: Check if status is effectively active
          if (data['status'] == 'Resolved') return _buildEmptyState(); 
          
          return _buildTaskCard(data, snapshot.data!.id);
        }
      );
    }
    
    // STRATEGY 2: Fallback Query (Legacy)
    return _buildQueryTaskStream();
  }

  Widget _buildQueryTaskStream() {
    return StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('all_reports')
            .where('assignedWorkerId', isEqualTo: _workerDocId)
            .orderBy('timestamp', descending: true)
            .limit(1)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return _buildEmptyState();
          }
          final doc = snapshot.data!.docs.first;
          return _buildTaskCard(doc.data() as Map<String, dynamic>, doc.id);
        }
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.grey[50], borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey[200]!)
      ),
      child: Column(
        children: [
          Icon(Icons.assignment_turned_in_outlined, size: 48, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text("No active assignments", style: GoogleFonts.poppins(color: Colors.grey[500], fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildTaskCard(Map<String, dynamic> task, String taskId) {
    String displayId = task['adminReportId'] ?? taskId.substring(0, 5).toUpperCase();
    String location = task['locationName'] ?? task['address'] ?? 'Unknown Location';
    String status = task['status'] ?? "Assigned";
    
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        // OLD UI: Very subtle shadow or just border. Using subtle shadow as per "Job Card" requirement
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 20, offset: const Offset(0, 10)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
             Navigator.push(context, MaterialPageRoute(builder: (_) => WorkerJobDetailsScreen(jobData: task, taskId: taskId)));
          },
          borderRadius: BorderRadius.circular(24),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(30)),
                          child: Text("JOB #$displayId", style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)),
                        ),
                        Icon(Icons.more_horiz, color: Colors.grey[400]),
                      ],
                    ),
                    const SizedBox(height: 15),
                    Text(task['category'] ?? 'Maintenance Task', 
                      style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)
                    ),
                    const SizedBox(height: 8),
                     Text(task['description'] ?? 'No Description provided.', 
                      style: GoogleFonts.poppins(fontSize: 14, color: Colors.black54, height: 1.5),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: Colors.blue[50], shape: BoxShape.circle),
                          child: const Icon(Icons.location_on_rounded, color: Colors.blue, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Location", style: GoogleFonts.poppins(fontSize: 10, color: Colors.grey[500], fontWeight: FontWeight.bold)),
                              Text(location, style: GoogleFonts.poppins(fontSize: 13, color: Colors.black87, fontWeight: FontWeight.w600), maxLines: 1),
                            ],
                          ),
                        )
                      ],
                    ),
                  ],
                ),
              ),
              
              Divider(height: 1, color: Colors.grey[100]),
              const SizedBox(height: 20),

              // ACTION BUTTON (Check In/Out) - Logic Preserved
              StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance.collection('attendance').doc(_getDailyDocId(_staffId, taskId: taskId)).snapshots(),
                builder: (context, snapshot) {
                   bool isCheckedIn = false;
                   bool isCheckedOut = false;
                   
                   if (snapshot.hasData && snapshot.data!.exists) {
                       final data = snapshot.data!.data() as Map<String, dynamic>;
                       isCheckedIn = true; 
                       isCheckedOut = data['checkOut'] != null;
                   }

                   String btnLabel = "CHECK IN (8:00 AM)";
                   IconData btnIcon = Icons.login_rounded;
                   Color btnBgColor = Colors.black; 
                   Color textColor = Colors.white;
                   VoidCallback? onPressed = () => _handleAttendance(task, taskId, _staffId, _workerName);

                   if (status == 'On-Hold') {
                       btnLabel = "JOB ON HOLD";
                       btnIcon = Icons.pause_circle_filled;
                       btnBgColor = Colors.grey[300]!; 
                       textColor = Colors.grey[600]!;
                       onPressed = null; 
                   } 
                   else if (isCheckedOut) {
                       btnLabel = "SHIFT COMPLETED";
                       btnIcon = Icons.check_circle;
                       btnBgColor = Colors.green.withOpacity(0.1); 
                       textColor = Colors.green;
                       onPressed = null;
                   } else if (isCheckedIn) {
                       btnLabel = "CHECK OUT (5:00 PM)";
                       btnIcon = Icons.logout_rounded;
                       btnBgColor = const Color(0xFFFF3D00); // Red
                       textColor = Colors.white;
                   }

                   return Padding(
                     padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                     child: SizedBox(
                       width: double.infinity,
                       child: ElevatedButton.icon(
                         onPressed: onPressed,
                         icon: Icon(btnIcon, size: 20, color: textColor),
                         label: Text(btnLabel, style: GoogleFonts.poppins(color: textColor, fontWeight: FontWeight.bold, fontSize: 13)),
                         style: ElevatedButton.styleFrom(
                           backgroundColor: btnBgColor,
                           disabledBackgroundColor: btnBgColor,
                           elevation: 0,
                           padding: const EdgeInsets.symmetric(vertical: 16),
                           shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                         ),
                       ),
                     ),
                   );
                }
              ),
            ],
          ),
        ),
      ),
    );
  }
}
