# Contributing to Active Monitor

We welcome contributions to the Active Monitor system! This project is maintained internally but follows standard open-source practices.

## Development Setup

### Admin Server

The heart of the system is the Admin PC (192.168.1.171). To test changes to the deployment workflow:

1. Verify the Update Server is running: `tasklist /FI "IMAGENAME eq pythonw.exe"`
2. Test the website locally at `http://localhost:8888`.

### Windows Monitor

1. Scripts are located in the repository root.
2. Use the `deploy-windows.bat` on a test VM or machine.
3. **Warning**: The script kills existing PowerShell monitors. Save your work!

### Mac Monitor

1. The Python script is embedded in the `file-monitor-mac.sh` Bash script.
2. Ensure you escape standard Python variables when modifying the Bash HEREDOC.

## Release Process

1. Make your changes.
2. Update `CHANGELOG.md` with a new entry.
3. Commit and Push to GitHub.
4. Run `setup-admin-pc.bat` on the Admin PC to pull the latest changes into the deployment folder.
