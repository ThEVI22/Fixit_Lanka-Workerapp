@echo off
git init
git remote add origin https://github.com/ThEVI22/Fixit_Lanka-Workerapp.git
git remote set-url origin https://github.com/ThEVI22/Fixit_Lanka-Workerapp.git
git add .
git commit -m "Initial commit"
git branch -M main
git push -u origin main
