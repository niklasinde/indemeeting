---
description: Show the time report for a week from MeetingRecorder, per project, branch and ticket
argument-hint: "[week start YYYY-MM-DD, or last]"
---

Call the `time_report` tool of the `meetingrecorder` MCP server. Arguments: `$ARGUMENTS`

- Empty: this week, so leave `week_start` out.
- A date (YYYY-MM-DD): pass it as `week_start`; any day of the week works.
- "last" or "previous": pass the date seven days before today.

Show the Markdown it returns as it is. Only add a short note below it when the user asked for something specific,
such as the hours of one ticket.
