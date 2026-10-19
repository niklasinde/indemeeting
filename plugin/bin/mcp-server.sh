#!/bin/sh
# Starts MeetingRecorder's read-only MCP server through the link the app keeps next to its database.
app="${MEETING_RECORDER_DATA_DIR:-$HOME/Library/Application Support/MeetingRecorder}/bin/meetingrecorder"
if [ ! -x "$app" ]; then
    echo "MeetingRecorder not found at $app. Open MeetingRecorder once so it can link itself there." >&2
    exit 1
fi
exec "$app" --mcp
