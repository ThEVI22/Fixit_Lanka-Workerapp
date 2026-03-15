@echo off
echo Creating assets folder...
mkdir assets
if exist assets echo Assets folder created.

echo Copying image...
copy "c:\Users\thevi\.gemini\antigravity\brain\930485c8-6c71-489a-8260-49c169dc0f66\worker_welcome_evening_1768593211946.png" "assets\worker_welcome_evening.png"

if exist "assets\worker_welcome_evening.png" (
    echo.
    echo SUCCESS: Image copied successfully!
    echo You can now run 'flutter run'.
) else (
    echo.
    echo ERROR: Could not copy image. Please check permissions.
)
pause
