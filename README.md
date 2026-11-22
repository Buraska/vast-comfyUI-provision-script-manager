# Vast ComfyUI Provision Script Manager

A local web UI that turns your bash **provision scripts** from a wall of shell lines into a
clickable table of models — with Civitai version checks, one-click add/delete, and git-based
sync to your Vast.ai server over SSH.

Two interchangeable implementations of the same tool:

- **`model_manager.py`** — Python 3.8+, standard library only (no pip packages), runs on
  Windows, Linux and macOS. Recommended.
- `model_manager.ps1` — the original single-file PowerShell 5.1 version for Windows.

Both speak the identical REST API and serve the identical web UI, and both read the same
`model_manager_settings.json`.

![Model Manager UI](docs/screenshot.png)

## The problem

Running AI workloads on [Vast.ai](https://vast.ai) means working in the console and repeating
the same steps over and over on every instance: installing ComfyUI, then downloading models,
loras, VAEs and text encoders from Civitai and HuggingFace.

The usual solution is a **provision script** — a bash file that runs when the instance starts
and downloads every model automatically. But the scripts themselves become the new problem:

- you cannot see *what* a script downloads without reading it line by line;
- checking whether a pinned Civitai version is still the latest means opening the site and
  comparing version IDs by hand;
- adding one model means writing yet another download line — and remembering which download
  helper and argument style *that particular script* uses;
- active and commented-out entries are mixed together with no overview.

If you have ever looked for a solution, you already know why: version checks and model
installation are too many repetitive steps for what they achieve.

## What this tool does

`model_manager.ps1` is a **single-file PowerShell tool**. Drop it into the folder that holds
your `*.sh` provision scripts, run it, and it opens a local web UI that:

- **lists every `*.sh` script** in the folder and parses all model download calls inside —
  Civitai (`civitai download`, `--version`, `--model`, custom helper functions) and
  HuggingFace (`hf download`, `download_hf_file` helpers, `wget` of resolve URLs),
- shows **source badges** (Civitai / HF), the parsed target dir, file names, sizes and
  direct links for every entry, including commented-out ones (shown dimmed as `off`),
- **Check new versions** — queries the Civitai API for every active civitai entry and marks
  each one `latest` (green) or `new: <version>` (orange, clicking it opens the new version
  on civitai.com). HF entries are intentionally not checked — HF files have no meaningful
  version concept,
- **Add model** — paste a Civitai or HuggingFace URL, the tool resolves it through the public
  APIs (model name, version, primary file, size; or a file picker for a whole HF repo) and
  inserts the download line in the exact call style that script already uses,
- **Disable / Enable** any entry (comments out / uncomments the block in the script) and
  **Delete** it — edits land on disk immediately, as UTF-8 without BOM with LF endings
  (bash-safe), with a one-shot `*.sh.bak` backup per session,
- **Save to git** — one button that commits the current script and pushes it to GitHub.

## Supported script format (importing your own provision script)

The parser reads every top-level `*.sh` file line by line. A line becomes a model entry if,
after stripping any leading `#` markers (so commented-out lines are imported as inactive
rows), it matches one of these forms. `<...>` are placeholders; `[...]` is optional.

### Civitai

```
download_civitai_primary <versionId> <dir> [# description]
civitai download --version <versionId> --out-dir <dir> [# description]
civitai download <versionId> --out-dir <dir> [# description]
civitai download --model <modelId> --out-dir <dir> [# description]
```

`download_civitai_primary` is the checksum-verified helper used by the bundled scripts; the
other three are the native `civitai` CLI forms. When you add a model through the UI, the
tool writes it in the dominant form already used by that script. `--model` entries serve
whatever the model's newest version is at runtime, so the version check only shows the
latest version name and never flags them as outdated.

### HuggingFace

```
download_hf_file \            # helper, single line or backslash-continued block
  <owner>/<repo> \
  <path/in/repo> \
  <target_dir>/<file_name>

hf download hf://<owner>/<repo>/<path> --local-dir <dir> [# description]
hf download <owner>/<repo> <file_name> --local-dir <dir> [# description]
download_hf hf://<owner>/<repo>/<path> <dir> [# description]
wget -P <dir> https://huggingface.co/<owner>/<repo>/resolve/<branch>/<path>
```

### How entries are treated

- **Line numbers are preserved.** Delete / Disable / Enable rewrite exactly the parsed line
  range, in place - the rest of the file (functions, exports, ComfyUI setup) is never
  touched, comments and indentation stay as they are, and every write is UTF-8 without BOM
  with LF endings. The file stays a valid bash script after any edit (verified with
  `bash -n`). Multi-line `download_hf_file` blocks are commented out / uncommented on every
  line, so a disabled block never leaves a bare continuation line behind.
- **Descriptions** resolve in this order: an inline `# comment` on the call line, then a
  standalone `#` comment line immediately above an *active* entry (no blank line between;
  lines that belong to a commented-out backslash block are ignored), otherwise empty.
- **Commented-out calls** (e.g. `# civitai download --version 123 ...`) are imported as
  dimmed `off` rows and can be re-enabled from the UI.
- **Literal arguments only.** Calls with shell variables or quotes, such as
  `download_hf_file "$GEMMA_REPO" "$FILE" "$PATH"`, cannot be parsed - they are reported as
  parse warnings in the UI instead of being silently dropped.
- **Target dir** is editable per entry; values may not contain spaces, `#`, quotes or `$`
  (anything else would break the bash line).
- **Download errors never kill the run.** Lines inserted by the tool carry a tolerance
  wrapper, so a failed download cannot abort the whole provision under `set -e`:

  ```bash
  civitai download --version 501240 --out-dir ./models/loras || echo '[provision] download failed: My Lora v2, continuing' >&2 # My Lora v2
  ```

  The parser understands this suffix on every supported form (hand-written unwrapped lines
  work as before, and toggling or retargeting a wrapped entry preserves the wrapper).
- **Custom helpers with other names** are not recognized. If your script wraps downloads in
  its own function, either name it like one of the helpers above or keep those lines in a
  form from the list; unrecognized lines are simply left untouched and untracked.

A minimal importable script looks like this:

```bash
#!/bin/bash
set -euo pipefail
cd /workspace/ComfyUI

civitai download --version 2540896 --out-dir ./models/diffusion_models # main checkpoint
download_hf_file \
  Comfy-Org/Wan_2.1_ComfyUI_repackaged \
  split_files/vae/wan_2.1_vae.safetensors \
  ./models/vae/wan_2.1_vae.safetensors
# civitai download --version 2668710 --out-dir ./models/diffusion_models  # imported as "off"
```

## Sync with your server over SSH

The classic Vast.ai workflow: your provision script lives in a git repository, and your
instance pulls or runs it over SSH at start.

1. Edit the model list in the UI (add, disable, delete).
2. Press **Save to git** — the tool commits and pushes the script.
3. On the server, `git pull` over SSH — or simply start the next instance from the updated
   script. The instance now downloads exactly the model list you saw in the UI.

## Usage

```powershell
# put model_manager.py into the folder with your *.sh provision scripts
cd C:\path\to\your\provision-scripts
python model_manager.py            # or: py model_manager.py
```

The UI opens at `http://localhost:8766` (the port auto-increments if taken). Useful flags:

```powershell
--port 8800            # fixed port
--no-browser           # do not auto-open the browser
--scripts-dir <path>   # manage scripts in another folder
```

The PowerShell version takes the equivalent parameters (`-Port`, `-NoBrowser`, `-ScriptsDir`).

### Scripts folder config

By default the tool manages the `*.sh` files next to itself. To run it from anywhere else,
set the folder once — either in the UI (**Folder** button) or by creating
`model_manager_settings.json` next to the tool:

```json
{ "scriptsDir": "C:\\path\\to\\your\\provision-scripts" }
```

Precedence: `--scripts-dir` parameter > `model_manager_settings.json` > folder of the tool itself.

### Requirements

- `model_manager.py`: Python 3.8+ — standard library only, nothing to install
- `model_manager.ps1`: Windows PowerShell 5.1 or 7
- git (for the **Save to git** button)
- optional: `CIVITAI_TOKEN` environment variable — sent as a Bearer token to reduce
  Civitai API rate limiting during version checks

## Safety

- The HTTP listener binds to `localhost` only, embeds a per-session random token into the
  page and rejects cross-origin requests.
- The UI never rewrites anything until *you* click Delete / Disable / Insert.
- Before the first mutation of a script in a session, a sidecar backup `<name>.sh.bak` is
  written; the folder being a git repository is the primary recovery path.
- Script names are strictly validated — no path traversal, only top-level `*.sh` files.

## Notes

- Only top-level `*.sh` files in the scripts folder are listed.
- Civitai version checks use the public API without auth unless `CIVITAI_TOKEN` is set;
  entries that fail to resolve degrade to `unknown` instead of blocking the rest.
- Parsing is non-destructive: the tool reads your scripts, it does not reformat them.

---

If you like it, please rate it — give the repo a ⭐ or drop feedback in the issues.
