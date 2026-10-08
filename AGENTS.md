# ai-assistant

This repo holds the shared system prompt (`system.md`), skills, agents, and commands linked into every supported agent CLI by `install.sh` / `install.ps1`.

## Writing rules, skills, and prompts

- Write rules as general positive descriptions of the outcome to achieve. Use a negative statement only where one replaces several positive ones. Either way, keep it general — do not name specific files, phrasings, or old wordings.
- When a stated claim turns out to be wrong, delete it by default. If the information must stay, rewrite it as one general principle rather than a different concrete assertion, which is just a new claim to refute.
