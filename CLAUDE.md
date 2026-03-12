# Claude Session Notes

## Vendored Submodules

- `vendor/frigate` — git submodule pointing to `git@github.com:peter-dolkens/frigate.git`
- Inside the submodule, `upstream` remote = `blakeblackshear/frigate`
- After cloning `/ai`, run `git submodule update --init` to populate `vendor/frigate`

## SELinux Notes

- `/ai/ai-stack.service` requires `systemd_unit_file_t` context
- Persistent policy already set: `semanage fcontext -a -t systemd_unit_file_t '/ai/ai-stack\.service'`
- If context resets: `sudo restorecon -v /ai/ai-stack.service && sudo systemctl daemon-reload`
