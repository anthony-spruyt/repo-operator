______________________________________________________________________

## name: block-proc-environ enabled: true event: bash pattern: cat\\s+/proc/(self|$$|[0-9]+)/environ action: block

🚫 **Blocked: Reading process environment from /proc**

**What was blocked:** Reading `/proc/self/environ`, `/proc/$$/environ`, or `/proc/[pid]/environ`

**Why:** These files contain ALL environment variables for a process, which may include secrets.

**If you need a specific variable:**

1. Ask the user: "What is the value of $VARIABLE_NAME?"
1. User can provide the value if it's safe
1. User can decline if it contains secrets

**Note:** This is a direct filesystem access to environment variables, bypassing normal shell commands.
