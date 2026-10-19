#!/bin/sh
# Appends one line per Claude Code hook event to MeetingRecorder's inbox. Prompt text, tool input and tool output are
# left out; MEETING_RECORDER_HOOK_PROMPTS=1 keeps the first 500 characters of each prompt. Never fails the session.
dir="${MEETING_RECORDER_DATA_DIR:-$HOME/Library/Application Support/MeetingRecorder}"
[ -d "$dir/claude-hooks" ] || mkdir -p "$dir/claude-hooks" 2>/dev/null || exit 0
awk -v dir="$dir" -v prompts="${MEETING_RECORDER_HOOK_PROMPTS:-0}" '
function field(key,    at, rest) {
    at = index(json, "\"" key "\"")
    if (!at) return ""
    rest = substr(json, at + length(key) + 2, 4096)
    if (!match(rest, /^[ \t]*:[ \t]*"([^"\\]|\\.)*"/)) return ""
    rest = substr(rest, 1, RLENGTH)
    sub(/^[ \t]*:[ \t]*"/, "", rest)
    return substr(rest, 1, length(rest) - 1)
}
function quoted(value) { return "\"" value "\"" }
{ json = json $0 }
END {
    event = field("hook_event_name"); id = field("session_id")
    if (event == "" || id !~ /^[A-Za-z0-9_-]+$/) exit
    srand(); now = srand()
    if (event == "PostToolUse") {
        stamp = dir "/claude-hooks/" id
        if ((getline last < stamp) > 0 && now - last < 30) exit
        close(stamp); print now > stamp; close(stamp)
    }
    line = "{\"time\":" now ",\"event\":" quoted(event) ",\"session_id\":" quoted(id) ",\"cwd\":" quoted(field("cwd")) \
        ",\"transcript_path\":" quoted(field("transcript_path"))
    if (event == "UserPromptSubmit") {
        prompt = field("prompt")
        plain = prompt; gsub(/\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]|\\./, "x", plain)
        line = line ",\"prompt_bytes\":" length(plain)
        if (prompts == "1") {
            prompt = substr(prompt, 1, 500)
            sub(/\\u[0-9a-fA-F]?[0-9a-fA-F]?[0-9a-fA-F]?$/, "", prompt)
            if (match(prompt, /\\+$/) && RLENGTH % 2) prompt = substr(prompt, 1, length(prompt) - 1)
            line = line ",\"prompt\":" quoted(prompt)
        }
    }
    if (event == "PostToolUse") line = line ",\"tool\":" quoted(field("tool_name"))
    if (event == "SessionStart") line = line ",\"source\":" quoted(field("source"))
    if (event == "SessionEnd") line = line ",\"reason\":" quoted(field("reason"))
    if (event == "Notification") line = line ",\"notification\":" quoted(field("notification_type"))
    print line "}" >> (dir "/claude-events.jsonl")
}' 2>/dev/null
exit 0
