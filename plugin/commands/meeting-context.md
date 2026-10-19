---
description: Bring in what you have been working on and which meetings you had (from MeetingRecorder)
argument-hint: "[hours, default 8]"
---

Call the `activity_context` tool of the `meetingrecorder` MCP server with `hours` set to `$ARGUMENTS` (use 8 when that
is empty or not a number). Show the Markdown it returns as it is, then use it as context for the rest of this
conversation. If the tool is unavailable, say that MeetingRecorder has to be opened once so the plugin can find it.
