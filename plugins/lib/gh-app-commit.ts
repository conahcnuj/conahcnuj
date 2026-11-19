export const API_COMMIT_SCRIPT = "api-commit.sh"
const SHELL_NAMES = new Set(["bash", "sh", "zsh", "ksh", "dash"])
// Command launchers that hand their remaining argv to the wrapped command.
// A `sudo git commit` or `env ./api-commit.sh` must be caught like the bare
// form, so the launcher word (and its own option words) is skipped and the
// wrapped command inspected in its place.
const LAUNCHER_NAMES = new Set(["command", "env", "nohup", "sudo", "time"])
const SEPARATOR_CHARS_RE = /[;&|()\n]/
const ASSIGNMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*=/
const SHELL_SCRIPT_FLAG_RE = /^-[a-zA-Z]*c[a-zA-Z]*$/
const GIT_OPTION_WITH_VALUE_RE = /^-[cC]$/

export function commandWords(cmd: string): string[][] {
  const segments: string[][] = []
  let words: string[] = []
  let word = ""
  let quote: '"' | "'" | null = null
  let quoted = false
  const endWord = () => {
    if (word || quoted) {
      words.push(word)
    }
    word = ""
    quoted = false
  }
  const endSegment = () => {
    endWord()
    if (words.length > 0) {
      segments.push(words)
    }
    words = []
  }
  for (const char of cmd) {
    if (quote) {
      if (char === quote) {
        quote = null
      } else {
        word += char
      }
      continue
    }
    if (char === '"' || char === "'") {
      quote = char
      quoted = true
      continue
    }
    if (SEPARATOR_CHARS_RE.test(char)) {
      endSegment()
      continue
    }
    if (/\s/.test(char)) {
      endWord()
      continue
    }
    word += char
  }
  endSegment()
  return segments
}

export function basename(token: string): string {
  const slash = Math.max(token.lastIndexOf("/"), token.lastIndexOf("\\"))
  return slash >= 0 ? token.slice(slash + 1) : token
}

export function* executedCommands(cmd: string): Generator<string[]> {
  for (const words of commandWords(cmd)) {
    let i = 0
    // Strip leading assignments and command launchers (sudo, env, nohup, ...):
    // a launcher hands its argv to the wrapped command, so `sudo git commit`
    // must block like the bare form. Repeating until stable lets
    // `env VAR=x sudo bash -c "git commit"` shed each layer in turn while
    // keeping the quoted script of a trailing `-c` intact for the shell
    // handling below.
    while (i < words.length) {
      if (ASSIGNMENT_RE.test(words[i])) {
        i += 1
        continue
      }
      if (LAUNCHER_NAMES.has(basename(words[i]).toLowerCase())) {
        i += 1
        while (i < words.length && words[i].startsWith("-")) {
          i += 1
        }
        continue
      }
      break
    }
    if (i >= words.length) {
      continue
    }
    if (!SHELL_NAMES.has(basename(words[i]).toLowerCase())) {
      yield words.slice(i)
      continue
    }
    let j = i + 1
    while (j < words.length && words[j].startsWith("-")) {
      if (SHELL_SCRIPT_FLAG_RE.test(words[j])) {
        const script = words[j + 1]
        if (script !== undefined) {
          yield* executedCommands(script)
        }
        j = words.length
        break
      }
      j += 1
    }
    if (j < words.length) {
      yield words.slice(j)
    }
  }
}

export function isGitCommitInvocation(words: string[]): boolean {
  const head = basename(words[0] ?? "").toLowerCase()
  if (head !== "git" && head !== "git.exe") {
    return false
  }
  let i = 1
  while (i < words.length && words[i].startsWith("-")) {
    i += GIT_OPTION_WITH_VALUE_RE.test(words[i]) ? 2 : 1
  }
  return /^commit(-|$)/.test(words[i] ?? "")
}

export function isGitCommitCommand(cmd: string): boolean {
  return [...executedCommands(cmd)].some(isGitCommitInvocation)
}

export function isDirectApiCommitCommand(cmd: string): boolean {
  return [...executedCommands(cmd)].some(
    (words) => basename(words[0] ?? "") === API_COMMIT_SCRIPT
  )
}

// --- transparent rewrite of `git commit` into `git vc` ----------------------


/**
 * Rewrite an exact `git ... commit` invocation into the equivalent
 * `git ... vc` invocation, so a plain `git commit` transparently becomes a
 * Verified commit. Returns the rewritten command, or null when nothing
 * changed. Only the bare `commit` subcommand is rewritten: `commit-tree`,
 * `commit-graph` and other plumbing keep their own meaning, and occurrences
 * inside quoted arguments, comments or unrelated commands are left alone.
 */
export function rewriteGitCommitToVc(cmd: string): string | null {
  type Token = { raw: string; value: string; start: number; end: number }

  function tokenize(seg: string): Token[] {
    const out: Token[] = []
    let i = 0
    const n = seg.length
    while (i < n) {
      if (/\s/.test(seg[i])) {
        i += 1
        continue
      }
      const start = i
      if (seg[i] === '"' || seg[i] === "'") {
        const quote = seg[i]
        i += 1
        while (i < n && seg[i] !== quote) {
          if (quote === '"' && seg[i] === "\\" && i + 1 < n) {
            i += 2
            continue
          }
          i += 1
        }
        if (i < n) {
          i += 1
        }
        out.push({ raw: seg.slice(start, i), value: seg.slice(start + 1, i - 1), start, end: i })
      } else {
        while (i < n && !/\s/.test(seg[i])) {
          i += 1
        }
        out.push({ raw: seg.slice(start, i), value: seg.slice(start, i), start, end: i })
      }
    }
    return out
  }

  function rewriteSegment(seg: string): string {
    const tokens = tokenize(seg)
    let idx = 0
    while (idx < tokens.length) {
      if (ASSIGNMENT_RE.test(tokens[idx].value)) {
        idx += 1
        continue
      }
      if (LAUNCHER_NAMES.has(basename(tokens[idx].value).toLowerCase())) {
        idx += 1
        while (idx < tokens.length && tokens[idx].value.startsWith("-")) {
          idx += 1
        }
        continue
      }
      break
    }
    if (idx >= tokens.length) {
      return seg
    }
    if (tokens[idx].value.startsWith("#")) {
      return seg
    }
    const cmdName = basename(tokens[idx].value).toLowerCase()
    if (SHELL_NAMES.has(cmdName)) {
      let j = idx + 1
      while (j < tokens.length && tokens[j].value.startsWith("-")) {
        if (SHELL_SCRIPT_FLAG_RE.test(tokens[j].value)) {
          const scriptToken = tokens[j + 1]
          if (scriptToken) {
            const rewritten = rewriteGitCommitToVc(scriptToken.value)
            if (rewritten !== null && rewritten !== scriptToken.value) {
              const quote =
                scriptToken.raw.startsWith("'") || scriptToken.raw.startsWith('"')
                  ? scriptToken.raw[0]
                  : ""
              const newRaw = quote ? quote + rewritten + quote : rewritten
              return seg.slice(0, scriptToken.start) + newRaw + seg.slice(scriptToken.end)
            }
          }
          break
        }
        j += 1
      }
      return seg
    }
    if (cmdName === "git" || cmdName === "git.exe") {
      let k = idx + 1
      while (k < tokens.length && tokens[k].value.startsWith("-")) {
        k += GIT_OPTION_WITH_VALUE_RE.test(tokens[k].value) ? 2 : 1
      }
      const commitToken = tokens[k]
      if (commitToken && commitToken.value === "commit") {
        return seg.slice(0, commitToken.start) + "vc" + seg.slice(commitToken.end)
      }
      return seg
    }
    return seg
  }

  const parts: Array<{ type: "seg" | "sep"; text: string }> = []
  let current = ""
  let quote: '"' | "'" | null = null
  for (let i = 0; i < cmd.length; i += 1) {
    const ch = cmd[i]
    if (quote) {
      current += ch
      if (ch === "\\" && quote === '"' && i + 1 < cmd.length) {
        current += cmd[i + 1]
        i += 1
        continue
      }
      if (ch === quote) {
        quote = null
      }
      continue
    }
    if (ch === '"' || ch === "'") {
      quote = ch
      current += ch
      continue
    }
    if (SEPARATOR_CHARS_RE.test(ch)) {
      if (current) {
        parts.push({ type: "seg", text: current })
        current = ""
      }
      parts.push({ type: "sep", text: ch })
    } else {
      current += ch
    }
  }
  if (current) {
    parts.push({ type: "seg", text: current })
  }

  let changed = false
  let out = ""
  for (const part of parts) {
    if (part.type === "sep") {
      out += part.text
    } else {
      const rewritten = rewriteSegment(part.text)
      if (rewritten !== part.text) {
        changed = true
      }
      out += rewritten
    }
  }
  return changed ? out : null
}
