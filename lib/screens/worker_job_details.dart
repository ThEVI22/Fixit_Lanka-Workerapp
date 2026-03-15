import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class WorkerJobDetailsScreen extends StatelessWidget {
  final Map<String, dynamic> jobData;
  final String taskId;

  const WorkerJobDetailsScreen({super.key, required this.jobData, required this.taskId});

  String _formatDate(dynamic timestamp) {
    if (timestamp == null) return "N/A";
    try {
      if (timestamp is Timestamp) {
        return DateFormat('MMM dd, yyyy').format(timestamp.toDate());
      } else if (timestamp is int) {
        return DateFormat('MMM dd, yyyy').format(DateTime.fromMillisecondsSinceEpoch(timestamp));
      } else if (timestamp is String) {
        return timestamp;
      }
    } catch (_) {}
    return "N/A";
  }

  @override
  Widget build(BuildContext context) {
    // Data Extraction with Fallbacks
    final String displayId = jobData['adminReportId'] ?? taskId.substring(0, 5).toUpperCase();
    final String dateStr = _formatDate(jobData['createdAtMs'] ?? jobData['date']);
    final String location = jobData['locationName'] ?? jobData['address'] ?? "No address provided";
    final String description = jobData['description'] ?? "No description provided.";
    final String status = jobData['status'] ?? 'Pending';


    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text("Job Details", style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status Badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _getStatusColor(status).withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _getStatusColor(status).withOpacity(0.2)),
              ),
              child: Text(
                status.toUpperCase(),
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _getStatusColor(status),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Title / ID
            Text(
              "Task #$displayId",
              style: GoogleFonts.poppins(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.calendar_today_outlined, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  dateStr,
                  style: GoogleFonts.poppins(fontSize: 14, color: Colors.grey[700]),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.timer_outlined, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  "Deadline: ${_formatDate(jobData['estimatedDate'] ?? jobData['deadline'])}",
                  style: GoogleFonts.poppins(fontSize: 14, color: Colors.red[400], fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Location Section
            _buildSectionHeader("Location"),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Row(
                children: [
                   Icon(Icons.location_on_outlined, color: Colors.blueGrey[400]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      location,
                      style: GoogleFonts.poppins(fontSize: 14, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Description Section
            _buildSectionHeader("Description"),
            const SizedBox(height: 8),
            Text(
              description,
              style: GoogleFonts.poppins(fontSize: 14, height: 1.6, color: Colors.black87),
            ),
            
            const SizedBox(height: 24),
            Divider(color: Colors.grey[200]),
            const SizedBox(height: 24),

             // Supervisor Info
            _buildSectionHeader("Assigned By"),
             const SizedBox(height: 8),
            Builder(
              builder: (context) {
                String name = jobData['supervisorName'] ?? jobData['assignedByName'] ?? "Site Supervisor";
                String role = jobData['supervisorRole'] ?? jobData['assignedByRole'] ?? "Operations Team";
                if (name.toLowerCase() == 'admin') name = "Site Administration";

                return Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.blueGrey[50], 
                      child: const Icon(Icons.person, color: Colors.grey),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name, 
                          style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 15),
                        ),
                        Text(
                          role,
                          style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    )
                  ],
                );
              }
            )
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.black),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'In-Work':
      case 'In-progress': return Colors.blue;
      case 'Resolved':
      case 'Completed': return Colors.green;
      case 'Pending': return Colors.orange;
      case 'Cancelled': 
      case 'Declined': return Colors.red;
      default: return Colors.grey;
    }
  }
}
