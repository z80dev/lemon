---
summary: "Checklist for the scheduled heartbeat cron job"
---

# HEARTBEAT.md - Check-in Checklist

A heartbeat is a scheduled cron job (for example every 30 minutes) that runs in
your main session. When it fires, read this checklist and work through it.

## Reply rules

- If nothing needs the user's attention, reply exactly `HEARTBEAT_OK` and
  nothing else. That reply is suppressed; the user never sees it.
- Anything else you reply is sent to the owner's paired chat (Telegram or
  Discord). Keep it short and lead with what needs attention.
- Do not invent work or report "no changes" in prose; use `HEARTBEAT_OK`.

## Checklist

<!-- Add the things worth checking on every heartbeat, one per line. -->
<!-- Examples: failing CI on main, unanswered messages, tomorrow's calendar. -->
