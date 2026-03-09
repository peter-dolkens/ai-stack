#!/bin/bash
# Clean up old code-interpreter generated images.
# Open WebUI accumulates these on every code "Run" click with no automatic cleanup.
# Keeps files newer than MAX_AGE_DAYS (default: 7).

UPLOADS="/ai/open-webui/uploads"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"
DRY_RUN="${1:-}"

echo "Removing *_generated-image.png files older than ${MAX_AGE_DAYS} days..."
[ "$DRY_RUN" = "--dry-run" ] && echo "(DRY RUN - no files will be deleted)"

if [ "$DRY_RUN" = "--dry-run" ]; then
    find "$UPLOADS" -name "*_generated-image.png" -mtime "+${MAX_AGE_DAYS}" -print
else
    find "$UPLOADS" -name "*_generated-image.png" -mtime "+${MAX_AGE_DAYS}" -print -delete
fi

echo "Done."
