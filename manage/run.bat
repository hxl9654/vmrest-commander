@echo off
if not exist node_modules\ (
    echo node_modules not found, running npm install...
    npm install
)

echo Starting VMRest-Commander Server...
start http://127.0.0.1:3001
node server.js
pause
