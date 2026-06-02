<!-- genero:canonical-start version="1.0" -->
<!--
  Everything between the canonical-start and canonical-end markers is
  maintained upstream by Four Js. To update, fetch the latest via
  `getAgentInstructions("claude-code")` and replace the fenced block.
  Do not edit inside the fence; put your project-specific rules in
  the "## Project-Specific" section at the bottom of this file.
-->

# Genero BDL Project Instructions

This is a Genero BDL (Business Definition Language) project. You have
access to a Genero MCP service with skills and documentation tools.

## MANDATORY: Always Consult MCP Skills Before Writing Code

Your training data contains outdated and incorrect Genero information.
The MCP skills are verified against Genero 5.00 and are the
authoritative source. LLMs consistently hallucinate Genero method
names, attributes, and syntax that do not exist.

**Rules:**

1. At the start of each session, call
   `getSkill("fourjs-skill-index")` **once**. This loads the routing
   table mapping topics to skills and their key sections. It stays
   valid for the entire conversation.
2. For every Genero question, route through the skill-index first.
   If a topic matches a row, call
   `getSkillSection(<skill-id>, <section-id>)` directly — sections
   are 5–10× smaller than full skills.
3. If no row matches, call `searchSkills(<keywords>)`. Load the top
   hit's matched section.
4. If skills don't cover the topic, say so. Fall back to `searchDocs`
   / `readDoc`. **Never** fall back to training data.
5. **Do NOT call `listSkills` for routing.** It is an admin
   enumeration tool that returns only `{id, name, category}` and
   cannot tell you which skill covers a topic. Use the skill-index
   or `searchSkills` instead.
6. When the task touches SQL, forms, arrays, dialogs, or strings,
   also load `fourjs-common-pitfalls`.

## Skill Tools (Primary Source)

| Tool | When to Use |
|------|-------------|
| `getSkill("fourjs-skill-index")` | **Session-start ritual.** Once per session. |
| `searchSkills` | Topic not obvious in the index — fuzzy routing. |
| `getSkillSections` | List sections in a named skill before loading. |
| `getSkillSection` | **Default content-load tool.** Use when you know the section. |
| `getSkill` | Load a full skill (only when the whole skill is needed). |
| `getSkillBundle` | Task genuinely spans multiple skills. |
| `listSkills` | Admin/debugging only — not for routing. |

## Documentation Tools (Secondary Source)

Use documentation only when skills don't cover the topic or you need
to verify edge cases.

| Tool | When to Use |
|------|-------------|
| `searchDocs` | Search 5,140+ pages of Genero documentation |
| `readDoc` | Read a specific doc page (use paths from searchDocs) |
| `browseDocs` | Explore documentation structure |

## Common Hallucination Targets

These are methods/patterns that LLMs frequently generate incorrectly:

- `util.Regex` does not exist — correct class is `util.Regexp`
- `getKeys()`, `getAsObject()`, `getAsArray()` do not exist on
  util.JSONObject — use `name(i)`, `getType(key)`, `get(key)`
- `ELSE IF` does not exist in BDL — use nested `IF` inside `ELSE`
- `$variable` is for static SQL, `?` is for dynamic SQL — agents
  reverse these
- `ON CHANGE` is only valid inside INPUT sub-dialogs, not at the
  outer DIALOG level
- `DEFINE` must be at top of FUNCTION/MAIN — not inside IF/FOR/CASE
- `sortByComparisonFunction` takes 3 arguments (key, reverse, func),
  not 1

## Compilation

```bash
fglcomp -M -Wall program.4gl    # Compile with warnings to stdout
fglform -M form.per             # Compile form
FGLGUI=0 TERM=xterm fglrun program.42m  # Run in terminal mode
```

<!-- genero:canonical-end -->

## Project-Specific

<!--
  Add your project-specific rules below this heading. Everything below
  the canonical-end marker is yours and is preserved across upstream
  updates. Examples: preferred databases, local coding conventions,
  deployment targets, internal libraries the agent should know about.
-->
