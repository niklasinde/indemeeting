#!/bin/sh
# Starts WorkTime's read-only MCP server through the link the app keeps next to its database.
bin="${WORKTIME_DATA_DIR:-${MEETING_RECORDER_DATA_DIR:-$HOME/Library/Application Support/MeetingRecorder}}/bin"
for app in "$bin/worktime" "$bin/meetingrecorder"; do
    [ -x "$app" ] && exec "$app" --mcp
done
echo "WorkTime not found at $bin/worktime. Open WorkTime once so it can link itself there." >&2
exit 1
