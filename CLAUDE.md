# Claude Session Notes

## SELinux Notes

- `/ai/ai-stack.service` requires `systemd_unit_file_t` context
- Persistent policy already set: `semanage fcontext -a -t systemd_unit_file_t '/ai/ai-stack\.service'`
- If context resets: `sudo restorecon -v /ai/ai-stack.service && sudo systemctl daemon-reload`
