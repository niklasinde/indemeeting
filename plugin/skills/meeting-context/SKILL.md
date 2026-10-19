---
name: meeting-context
description: Look up the user's own meetings and tracked work with the meetingrecorder MCP tools. Use when the user asks about a meeting ("what did we decide in the standup", "who owns the release action item", "what did Anna say about the migration"), what they were working on ("what was I doing this morning", "which branch was I on yesterday"), or how they spent their time ("how many hours on QDLY-8296 this week"), or when that context would make an answer better.
---

MeetingRecorder runs on the user's Mac and records meetings (transcript with speakers, summary, action items, notes)
and their activity (apps, repositories, branches, tickets, Claude Code sessions). Its MCP server `meetingrecorder`
reads that database without changing it.

Pick the tool:

- `recent_meetings` for "my last meetings" or to find a meeting by when it happened.
- `search_meetings` with a few distinctive words when the user names a topic, person or decision; it searches titles,
  transcripts, summaries and notes. Try the words in the meeting's language too (meetings are often in Swedish).
- `get_meeting` with an `id` from either of those for the summary, action items, notes and the transcript with
  speakers. Quote the transcript when the user asks what someone said.
- `activity_context` with `hours` for what the user worked on lately: apps, repositories, branches, tickets, Claude
  sessions and the meetings in that time.
- `time_report` with an optional `week_start` (YYYY-MM-DD) for hours per day, project, branch and ticket.

Say which meeting (title and date) an answer comes from. When nothing matches, say so instead of guessing. Everything
is local; do not send it anywhere the user did not ask for.
