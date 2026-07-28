-- tag-format: say how projects, contexts and tags should look.
--
-- A todo.txt line carries its metadata in the open — `+work`, `@phone`,
-- `due:2026-08-01`, and whatever `key:value` a plugin keeps. That is the format's
-- great virtue in a file and its main cost in a list: the words you actually read
-- share a row with bookkeeping you already know.
--
-- So this plugin does not change the file. It changes how a tag is *drawn*:
-- rewrite its text, recolour it, or drop it from the row. One rule a line:
--
--   +urgent  = 🔥{value}          fg:#f38ba8
--   @waiting =                    fg:#89b4fa bg:#1e1e2e
--   due      = ⏰{value}          fg:#f9e2af
--   _pomo    = 🍅{value}          show
--   _kanban  =                    hide
--
-- # Why `before_render` rather than a filter or a source
--
-- Because this is presentation and nothing else. A hook that returns parts cannot
-- change what the list contains, cannot reorder it, and cannot reach the file —
-- the host owns serialization, so the worst a bad rule can do is look wrong until
-- it is fixed.
--
-- # What a rule matches
--
-- The selector is the tag as it is written, minus the value:
--
--   +name   a project            +*   any project
--   @name   a context            @*   any context
--   key     a `key:value` tag    *    any `key:value` tag
--
-- `due`, `t` and `rec` are `key:value` tags to the format and to a rule, so
-- `due` and `t` are selectors like any other. First matching rule wins, so put
-- the specific ones above the wildcards.
--
-- # What a rule may say
--
--   a label   the text to draw. `{value}` is the bare value, `{key}` the key,
--             `{text}` what the row would have drawn. An empty label keeps the
--             original text — useful when the rule is only about colour.
--   fg:#hex   text colour, `#rrggbb` or `#rrggbbaa`
--   bg:#hex   background behind the tag
--   hide      leave the tag out of the row (it stays in the file)
--   show      draw a hidden (`_`-prefixed) tag that would be left out
--
-- Blank lines and `#` comments are ignored. A line that cannot be read is
-- reported by the configure window and skipped; one typo does not cost the rest.

local RULES_KEY = "rules"

-- The rules as the user last wrote them. Kept as the text they typed rather than
-- as a parsed structure: it is what the editor shows, it is what a comment
-- survives in, and reparsing it is a few microseconds a document load.
local DEFAULT_RULES = [[
# One rule a line:  <selector> = <label>  [fg:#hex] [bg:#hex] [hide|show]
# Selectors: +project  @context  key   (or +*  @*  *)
# In the label, {value} is the tag's value, {key} its key, {text} the original.

# _pomo   = 🍅{value}   show
# _kanban =             hide
# due     = ⏰{value}    fg:#f9e2af
]]

local ui = { text = "", status = "" }

--- Trim both ends. Lua has no `string.trim`.
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Whether `s` is `#rrggbb` or `#rrggbbaa`.
---
--- Checked here rather than passed through to the host: an unparseable colour is
--- a silent no-op at the far end, and the point of the configure window is to say
--- which line is wrong while the user is still looking at it.
local function is_hex_colour(s)
  return s:match("^#%x%x%x%x%x%x$") ~= nil or s:match("^#%x%x%x%x%x%x%x%x$") ~= nil
end

--- One rule from one line, or nil plus the reason it was refused.
---
--- Returns nil, nil for a line that is not a rule at all (blank, comment), so a
--- caller can tell "nothing here" from "this is wrong".
local function parse_rule(line)
  local bare = trim(line)
  if bare == "" or bare:sub(1, 1) == "#" then
    return nil, nil
  end
  local selector, rest = bare:match("^(%S+)%s*=%s*(.*)$")
  if not selector then
    return nil, "no `=` in the line"
  end

  local rule = { selector = selector }
  -- The label is whatever comes before the first option word, so a label may
  -- contain spaces and emoji without being quoted.
  local label_parts = {}
  for word in rest:gmatch("%S+") do
    local key, value = word:match("^(fg):(#%S+)$")
    if not key then
      key, value = word:match("^(bg):(#%S+)$")
    end
    if key then
      if not is_hex_colour(value) then
        return nil, "not a colour: " .. value
      end
      rule[key] = value
    elseif word == "hide" then
      rule.hide = true
    elseif word == "show" then
      rule.show = true
    else
      label_parts[#label_parts + 1] = word
    end
  end
  rule.label = trim(table.concat(label_parts, " "))
  if rule.hide and rule.show then
    return nil, "both hide and show"
  end
  return rule, nil
end

--- Every rule in `text`, in order, plus a list of `{ line, why }` for the ones
--- refused.
local function parse_rules(text)
  local rules, problems = {}, {}
  local number = 0
  -- `(.-)\n` over the text plus a trailing newline, not `[^\n]*`: the latter also
  -- matches the empty string after every line, so each line would be counted
  -- twice and the reported line numbers would be wrong.
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    local rule, why = parse_rule(line)
    if rule then
      rules[#rules + 1] = rule
    elseif why then
      problems[#problems + 1] = { line = number, why = why }
    end
  end
  return rules, problems
end

--- The selector a part would be written as, and the wildcard that also matches
--- it: `+work` / `+*`, `@phone` / `@*`, `due` / `*`.
---
--- `kind` rather than the drawn text, because the drawn text is what a previous
--- rule may already have rewritten.
local function selectors_for(part)
  if part.kind == "project" then
    return "+" .. part.value, "+*"
  elseif part.kind == "context" then
    return "@" .. part.value, "@*"
  elseif
    part.kind == "tag"
    or part.kind == "due"
    or part.kind == "threshold"
    or part.kind == "recurrence"
  then
    -- The key is not carried separately, so it is the drawn `key:value` minus
    -- the value. A `due` part draws as `due:2026-08-01`.
    local key = part.text:match("^([^:]+):") or part.kind
    return key, "*"
  end
  return nil, nil
end

--- `%` doubled, so a value containing one survives being a `gsub` replacement.
---
--- A task may well carry `due:2026-08-15` and a project called `+50%done`; `%d`
--- in a replacement string is a capture reference, and an unescaped `%` at the
--- end of one raises.
local function escape_replacement(s)
  return (tostring(s or ""):gsub("%%", "%%%%"))
end

--- `label` with its placeholders filled in from `part`.
local function expand(label, part, key)
  local out = label:gsub("{value}", escape_replacement(part.value))
  out = out:gsub("{key}", escape_replacement(key))
  out = out:gsub("{text}", escape_replacement(part.text))
  return out
end

local rules = parse_rules(taskle.state.get(RULES_KEY) or DEFAULT_RULES)

taskle.on("before_render", function(ctx)
  if #rules == 0 then
    return nil
  end
  local parts = ctx.task.parts
  local touched = false
  for _, part in ipairs(parts) do
    local exact, wildcard = selectors_for(part)
    if exact then
      for _, rule in ipairs(rules) do
        if rule.selector == exact or rule.selector == wildcard then
          if rule.label ~= "" then
            part.text = expand(rule.label, part, exact)
          end
          if rule.fg then
            part.fg = rule.fg
          end
          if rule.bg then
            part.bg = rule.bg
          end
          if rule.hide then
            part.hidden = true
          elseif rule.show then
            part.hidden = false
          end
          touched = true
          -- First match wins: a specific rule above a wildcard is the whole
          -- reason the list is ordered.
          break
        end
      end
    end
  end
  -- Returning nil leaves the row alone, which is cheaper than handing back an
  -- untouched array for every task in a document no rule mentions.
  if not touched then
    return nil
  end
  return parts
end)

-- ===== the configure window =====
--
-- A text area rather than a row of widgets per rule: the rules are a short list a
-- user edits in bulk, comments and all, and a form would turn "add a colour to
-- three tags" into nine controls and a scrollbar.

local function view()
  return taskle.ui.column {
    taskle.ui.text { "Tag Format", tone = "heading" },
    taskle.ui.text {
      "One rule a line:  <selector> = <label>  [fg:#hex] [bg:#hex] [hide|show]",
      tone = "dim",
    },
    taskle.ui.text {
      "Selectors: +project  @context  key  (or +*  @*  *). {value} {key} {text} in the label.",
      tone = "dim",
    },
    taskle.ui.text_area {
      id = "rules",
      value = ui.text,
      placeholder = "+urgent = 🔥{value}   fg:#f38ba8",
      on_input = "edit",
      height = 260,
    },
    taskle.ui.row {
      taskle.ui.button { "Save", on_press = "save", style = "primary" },
      taskle.ui.button { "Reload saved", on_press = "reload" },
      taskle.ui.button { "Restore the example", on_press = "reset" },
      taskle.ui.space {},
      taskle.ui.text { ui.status, tone = "accent" },
    },
    spacing = 6,
  }
end

local function save()
  local parsed, problems = parse_rules(ui.text)
  taskle.state.set(RULES_KEY, ui.text)
  rules = parsed
  if #problems == 0 then
    ui.status = #parsed == 1 and "1 rule saved." or (#parsed .. " rules saved.")
  else
    -- Saved anyway, minus the bad lines: refusing the whole edit would throw away
    -- the rules that are fine because one line has a typo in it.
    local first = problems[1]
    ui.status = ("%d saved, %d skipped — line %d: %s"):format(
      #parsed,
      #problems,
      first.line,
      first.why
    )
  end
end

local function update(_, message, value)
  if message == "edit" then
    ui.text = value or ""
    ui.status = ""
  elseif message == "save" then
    save()
  elseif message == "reload" then
    -- The editor keeps an unsaved buffer for as long as the app runs, so this is
    -- how an abandoned edit is thrown away: there is no host message for "the
    -- window was shown" to do it automatically.
    ui.text = taskle.state.get(RULES_KEY) or DEFAULT_RULES
    ui.status = "Reloaded the saved rules."
  elseif message == "reset" then
    ui.text = DEFAULT_RULES
    ui.status = "Example restored — Save to apply it."
  end
end

ui.text = taskle.state.get(RULES_KEY) or DEFAULT_RULES

taskle.window {
  id = "tag-format",
  title = "Tag Format",
  command = "tag-format.configure",
  view = view,
  update = update,
}

-- Under View, with the other things that change how the list is drawn rather
-- than what it contains.
taskle.menu {
  title = "Tag Format…",
  command = "tag-format.configure",
  menu = "View",
}
