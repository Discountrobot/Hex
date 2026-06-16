---
"hex-app": patch
---

Project avatars in the Agent Plugins voice window work under the App Sandbox again. The GitHub owner is now resolved by the hook (which runs unsandboxed and can read the repo's git remote) and passed to Hex, instead of the sandboxed app trying to spawn `git` against a project directory outside its container.
