---
"hex-app": minor
---

Add **Agent Plugins** — an opt-in Claude Code integration with a floating voice window (#2). When an installed agent finishes a turn, asks a multiple-choice question, or requests a permission, a window appears so you can answer by voice, typing, or tapping an option without leaving your editor.

- **Sandbox-friendly install:** Hex stays sandboxed and never edits `~/.claude` itself. Settings → Agent Plugins shows a one-time copy-paste terminal command that registers the hooks; the hook and Hex exchange messages through Hex's own container.
- **In-band replies:** answers are delivered to the exact Claude session via a response file the hook relays — they can never land in the wrong window.
- **Concurrent sessions:** blocked sessions queue one card at a time, and a header selector of project avatars (the repo's GitHub owner) switches between the ones waiting.
- **Stays out of your way:** a hook-driven card appears passively without stealing keyboard focus from the editor you're typing in; engage it to reply, and any Enter (with or without a modifier) sends.
- **Optional read-aloud:** agent output can be spoken on-device via Kokoro TTS, with a selectable voice and a distinct voice per concurrent project.
