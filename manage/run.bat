@echo off
if not exist node_modules\ (
    echo node_modules not found, running npm install...
    npm install
)

echo Starting VMRest-Commander Server...
node server.js
pause
