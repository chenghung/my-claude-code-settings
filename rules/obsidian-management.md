# Instruction

use the `obsidian-manager` subagent for all structural operations on an Obsidian vault, including: creating, renaming, moving, or deleting notes; opening, appending to, or prepending daily notes; querying backlinks, orphans, and unresolved links; listing, renaming, or querying tags; reading or modifying properties and frontmatter; and listing or inserting templates.

Note content authoring and editing is outside this subagent's scope and is handled separately.

## Collaboration Flow Between obsidian-md-editor and obsidian-manager

### Creating a New Note with Initial Content

When the task requires creating a new note that needs initial content:

1. Delegate to `obsidian-md-editor` first to author the content and write it to a temp file under the workspace `.tmp` directory, following the location rules defined in the `tmp-file-usage` rule.
1. Then delegate to `obsidian-manager`, passing the temp file path so it can read the content and create the note inside the vault.
1. After the note is confirmed created, clean up the temp file.

### Creating a New Note Without Initial Content

When the task only needs an empty note (for example, a placeholder the user will fill in manually), delegate directly to `obsidian-manager`. There is no need to involve `obsidian-md-editor`.

### Editing the Body of an Existing Note

Body content edits on an existing vault note are handled by `obsidian-md-editor` operating directly on the vault file. There is no need to involve `obsidian-manager`, and no temp file handoff is required.

### Structural Operations

Renaming, moving, deleting a note, modifying frontmatter properties, and querying backlinks or link relationships are always delegated to `obsidian-manager`.
