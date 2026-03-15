import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class CustomDialog extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String primaryActionText;
  final VoidCallback onPrimaryAction;
  final String secondaryActionText;
  final VoidCallback? onSecondaryAction;
  final Color primaryColor;
  final Color? iconColor;
  final Color? iconContainerColor;

  const CustomDialog({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.primaryActionText,
    required this.onPrimaryAction,
    this.secondaryActionText = "Cancel",
    this.onSecondaryAction,
    this.primaryColor = Colors.black,
    this.iconColor,
    this.iconContainerColor,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      backgroundColor: Colors.white,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: iconContainerColor ?? Colors.black.withOpacity(0.06), shape: BoxShape.circle),
              child: Icon(icon, size: 28, color: iconColor ?? Colors.black),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.black),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(fontSize: 13, color: Colors.black54, height: 1.5),
            ),
            const SizedBox(height: 24),
            secondaryActionText.isEmpty
            ? SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onPrimaryAction,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Text(
                    primaryActionText,
                    style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                ),
              )
            : Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onSecondaryAction ?? () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.black.withOpacity(0.12)),
                      padding: const EdgeInsets.symmetric(vertical: 12.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      secondaryActionText,
                      style: GoogleFonts.poppins(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onPrimaryAction,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      primaryActionText,
                      style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}
