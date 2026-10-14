-- Deterministic validation and todo.txt composition for todo-ai evidence.
--
-- The model is never allowed to render a task directly, and this module is
-- never allowed to read meaning out of the raw text. It accepts the evidence
-- result, validates every byte span, structured field and confidence, resolves
-- the temporal evidence against the reference date, and returns either a
-- structured Taskle draft or a fail-closed verdict.

local policy = {}

local OUTCOME_CONFIDENCE = 0.90
local FIELD_CONFIDENCE = 0.85
local PRIORITY_CONFIDENCE = 0.90
local RECURRENCE_CONFIDENCE = 0.90
local MAX_EVIDENCE = 32
local MAX_INTERVAL = 999

local LABELS = {
  TASK = true,
  PRIORITY = true,
  PROJECT = true,
  CONTEXT = true,
  DATE = true,
  TIME = true,
  RECURRENCE = true,
}

local RECURRENCE_UNITS = {
  d = true,
  w = true,
  m = true,
  y = true,
  b = true,
}

-- Text between spans has to be a connective the sentence could not do without.
-- Nothing here may carry meaning of its own: a word that names a day, a time
-- or a repetition would let the thing it names vanish unrecorded, which is the
-- failure this check exists to prevent.
local GAP_WORDS = {
  a = true,
  add = true,
  an = true,
  ["and"] = true,
  at = true,
  by = true,
  context = true,
  create = true,
  due = true,
  ["for"] = true,
  ["in"] = true,
  it = true,
  list = true,
  me = true,
  my = true,
  ["of"] = true,
  on = true,
  please = true,
  priority = true,
  project = true,
  put = true,
  remember = true,
  remind = true,
  reminder = true,
  ["repeat"] = true,
  schedule = true,
  set = true,
  task = true,
  the = true,
  time = true,
  to = true,
  up = true,
  with = true,
}

-- Punctuation the sentence frames use to separate clauses. Dashes and the
-- ellipsis are multi-byte, so they are matched as sequences rather than added
-- to a byte class.
local GAP_PUNCTUATION = { "\226\128\148", "\226\128\147", "\226\128\166" }

local function verdict(status, code, message)
  return { status = status, code = code, message = message }
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_integer(value)
  return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function is_confidence(value)
  return type(value) == "number" and value >= 0 and value <= 1
end

local function is_leap_year(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function days_in_month(year, month)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and is_leap_year(year) then
    return 29
  end
  return days[month]
end

local function parse_iso_date(value)
  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if not year or month < 1 or month > 12 then
    return nil
  end
  local maximum = days_in_month(year, month)
  if day < 1 or day > maximum then
    return nil
  end
  return year, month, day
end

local function format_date(year, month, day)
  return ("%04d-%02d-%02d"):format(year, month, day)
end

local function tomorrow(reference_date)
  local year, month, day = parse_iso_date(reference_date)
  if not year then
    return nil
  end
  day = day + 1
  if day > days_in_month(year, month) then
    day = 1
    month = month + 1
    if month > 12 then
      month = 1
      year = year + 1
    end
  end
  return format_date(year, month, day)
end

local function add_days(reference_date, count)
  local value = reference_date
  for _ = 1, count do
    value = tomorrow(value)
  end
  return value
end

local function weekday_index(reference_date)
  local year, month, day = parse_iso_date(reference_date)
  if not year then
    return nil
  end
  local offsets = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if month < 3 then
    year = year - 1
  end
  return (
    year
    + math.floor(year / 4)
    - math.floor(year / 100)
    + math.floor(year / 400)
    + offsets[month]
    + day
  ) % 7
end

-- Written and spoken forms share one table because a weekday phrase resolves
-- the same way however it was abbreviated.
local WEEKDAYS = {
  sunday = 0,
  monday = 1,
  tuesday = 2,
  wednesday = 3,
  thursday = 4,
  friday = 5,
  saturday = 6,
  sun = 0,
  mon = 1,
  tue = 2,
  tues = 2,
  wed = 3,
  weds = 3,
  thu = 4,
  thur = 4,
  thurs = 4,
  fri = 5,
  sat = 6,
}

local MONTHS = {
  january = 1,
  february = 2,
  march = 3,
  april = 4,
  may = 5,
  june = 6,
  july = 7,
  august = 8,
  september = 9,
  october = 10,
  november = 11,
  december = 12,
  jan = 1,
  feb = 2,
  mar = 3,
  apr = 4,
  jun = 6,
  jul = 7,
  aug = 8,
  sep = 9,
  sept = 9,
  oct = 10,
  nov = 11,
  dec = 12,
}

local function add_months(reference_date, count)
  local year, month, day = parse_iso_date(reference_date)
  if not year then
    return nil
  end
  local index = year * 12 + (month - 1) + count
  year = math.floor(index / 12)
  month = index % 12 + 1
  local maximum = days_in_month(year, month)
  if day > maximum then
    day = maximum
  end
  return format_date(year, month, day)
end

-- `inclusive` is what separates an anchor from a phrase. "every monday" on a
-- Monday is due today; "on monday" said on a Monday means the next one.
local function weekday_on_or_after(reference_date, target, inclusive)
  local current = weekday_index(reference_date)
  if current == nil then
    return nil
  end
  local offset = (target - current) % 7
  if offset == 0 and not inclusive then
    offset = 7
  end
  return add_days(reference_date, offset)
end

-- The first month at or after the reference date that actually has that day.
-- A 31st is not silently moved to the 30th: the user named a day, so months
-- without it are skipped rather than rewritten.
local function day_of_month_on_or_after(reference_date, target, inclusive)
  local year, month, day = parse_iso_date(reference_date)
  if not year or target < 1 or target > 31 then
    return nil
  end
  local passed = target < day or (target == day and not inclusive)
  for step = passed and 1 or 0, 12 do
    local candidate = add_months(format_date(year, month, 1), step)
    local candidate_year, candidate_month = parse_iso_date(candidate)
    if target <= days_in_month(candidate_year, candidate_month) then
      return format_date(candidate_year, candidate_month, target)
    end
  end
  return nil
end

local ORDINAL_SUFFIXES = { st = true, nd = true, rd = true, th = true }

local function ordinal_day(value)
  local digits, suffix = value:match("^(%d%d?)(%a%a)$")
  if not digits or not ORDINAL_SUFFIXES[suffix] then
    return nil
  end
  return tonumber(digits)
end

local NUMBER_WORDS = {
  a = 1,
  an = 1,
  one = 1,
  two = 2,
  three = 3,
  four = 4,
  five = 5,
  six = 6,
  seven = 7,
  eight = 8,
  nine = 9,
  ten = 10,
  eleven = 11,
  twelve = 12,
}

local ORDINAL_WORDS = {}
do
  local units = {
    "first",
    "second",
    "third",
    "fourth",
    "fifth",
    "sixth",
    "seventh",
    "eighth",
    "ninth",
  }
  local teens = {
    "tenth",
    "eleventh",
    "twelfth",
    "thirteenth",
    "fourteenth",
    "fifteenth",
    "sixteenth",
    "seventeenth",
    "eighteenth",
    "nineteenth",
  }
  for index, word in ipairs(units) do
    ORDINAL_WORDS[word] = index
    ORDINAL_WORDS["twenty " .. word] = 20 + index
  end
  for index, word in ipairs(teens) do
    ORDINAL_WORDS[word] = index + 9
  end
  ORDINAL_WORDS.twentieth = 20
  ORDINAL_WORDS.thirtieth = 30
  ORDINAL_WORDS["thirty first"] = 31
end

-- A day of the month written any of the ways people write one: a numeral, a
-- numeric ordinal, or an ordinal word.
local function day_number(value)
  local digits = value:match("^(%d%d?)$")
  if digits then
    return tonumber(digits)
  end
  return ordinal_day(value) or ORDINAL_WORDS[value]
end

local function whole_number(value)
  local digits = value:match("^(%d+)$")
  if digits then
    return tonumber(digits)
  end
  return NUMBER_WORDS[value]
end

local RELATIVE_DAYS = {
  today = 0,
  tomorrow = 1,
  ["day after tomorrow"] = 2,
}

local RELATIVE_UNITS = {
  day = "d",
  days = "d",
  week = "w",
  weeks = "w",
  month = "m",
  months = "m",
  year = "y",
  years = "y",
}

local function shift(reference_date, unit, count)
  if unit == "d" then
    return add_days(reference_date, count)
  end
  if unit == "w" then
    return add_days(reference_date, count * 7)
  end
  if unit == "m" then
    return add_months(reference_date, count)
  end
  if unit == "y" then
    return add_months(reference_date, count * 12)
  end
  return nil
end

-- Words that qualify a phrase without moving the day it names. Stripping them
-- lets one branch per concept cover every way the concept is introduced:
-- "by Monday", "on Monday" and "Monday" are one phrase, not three.
local LEAD_WORDS = {
  around = true,
  before = true,
  by = true,
  due = true,
  on = true,
  over = true,
  the = true,
}

local function strip_lead(value, words)
  local head, rest = value:match("^(%a+) (.+)$")
  while head and words[head] do
    value = rest
    head, rest = value:match("^(%a+) (.+)$")
  end
  return value
end

local function last_day_of_month(year, month)
  return format_date(year, month, days_in_month(year, month))
end

-- A calendar date named without a year means the next one that has not gone
-- past. Naming January in July means next January, not one seven months gone.
local function month_day_on_or_after(reference_date, month, day, year)
  local reference_year = parse_iso_date(reference_date)
  if not reference_year or not month or not day or day < 1 then
    return nil
  end
  if year then
    if day > days_in_month(year, month) then
      return nil
    end
    return format_date(year, month, day)
  end
  for step = 0, 4 do
    local candidate_year = reference_year + step
    if day <= days_in_month(candidate_year, month) then
      local candidate = format_date(candidate_year, month, day)
      if candidate >= reference_date then
        return candidate
      end
    end
  end
  return nil
end

local function month_end_on_or_after(reference_date, month)
  local reference_year = parse_iso_date(reference_date)
  if not reference_year then
    return nil
  end
  for step = 0, 4 do
    local candidate = last_day_of_month(reference_year + step, month)
    if candidate >= reference_date then
      return candidate
    end
  end
  return nil
end

-- A month name beside a day, in either order, with an optional year:
-- "August 1", "1 Aug", "August 1st 2026", "mid-August".
local function month_phrase(value, reference_date)
  local words = {}
  for word in value:gmatch("%S+") do
    words[#words + 1] = word
  end
  if #words < 2 or #words > 3 then
    return nil
  end
  local year = nil
  if #words == 3 then
    year = tonumber(words[3]:match("^(%d%d%d%d)$"))
    if year then
      words[3] = nil
    else
      -- The tail is a two-word ordinal such as "twenty first" instead.
      words = { words[1], words[2] .. " " .. words[3] }
    end
  end
  local first, second = words[1], words[2]
  if first == "mid" and MONTHS[second] then
    return month_day_on_or_after(reference_date, MONTHS[second], 15, year)
  end
  if MONTHS[first] then
    return month_day_on_or_after(reference_date, MONTHS[first], day_number(second), year)
  end
  if MONTHS[second] then
    return month_day_on_or_after(reference_date, MONTHS[second], day_number(first), year)
  end
  return nil
end

-- Resolves one DATE phrase against the reference date. The accepted set is
-- fixed and matches the phrases the model is trained to label; anything else
-- fails closed rather than being guessed at.
local function resolve_date(raw, reference_date)
  local reference_year = parse_iso_date(reference_date)
  if not reference_year then
    return nil
  end
  local value = trim(raw):lower():gsub("^due:%s*", ""):gsub("%s+", " ")
  value = strip_lead(trim(value), LEAD_WORDS)

  if parse_iso_date(value) then
    return value
  end

  -- Past this point a hyphen only ever joins words — "mid-August",
  -- "twenty-first" — because the one hyphenated number form is an ISO date.
  value = trim((" " .. value:gsub("%-", " ") .. " "):gsub(" the ", " "):gsub("%s+", " "))

  local days = RELATIVE_DAYS[value]
  if days then
    return add_days(reference_date, days)
  end

  local relative = value:match("^this time (.+)$")
  if relative then
    return resolve_date(relative, reference_date)
  end

  local weekday = value:match("^next (%a+)$")
    or value:match("^this (%a+)$")
    or value:match("^(%a+)$")
  if weekday and WEEKDAYS[weekday] then
    return weekday_on_or_after(reference_date, WEEKDAYS[weekday], false)
  end

  -- A weekend is the Saturday it opens on.
  if value == "weekend" or value == "this weekend" or value == "next weekend" then
    return weekday_on_or_after(reference_date, WEEKDAYS.saturday, false)
  end

  local unit = value:match("^next (%a+)$")
  if unit and RELATIVE_UNITS[unit] then
    return shift(reference_date, RELATIVE_UNITS[unit], 1)
  end

  local count, interval_unit = value:match("^in (%S+) (%a+)$")
  if not count then
    count, interval_unit = value:match("^(%S+) (%a+) from now$")
  end
  if count and RELATIVE_UNITS[interval_unit] then
    count = whole_number(count)
    if count and count >= 1 and count <= MAX_INTERVAL then
      return shift(reference_date, RELATIVE_UNITS[interval_unit], count)
    end
    return nil
  end

  -- The closing edge of a named period. "before July ends" and "by the end of
  -- the month" are the same request said from opposite directions.
  local period = value:match("^end of (%a+)$")
    or value:match("^(%a+) end$")
    or value:match("^this (%a+) ends$")
    or value:match("^(%a+) ends$")
  if period then
    if period == "today" then
      return reference_date
    end
    if period == "week" then
      return weekday_on_or_after(reference_date, WEEKDAYS.sunday, false)
    end
    if period == "month" then
      local _, reference_month = parse_iso_date(reference_date)
      return last_day_of_month(reference_year, reference_month)
    end
    if period == "year" then
      return format_date(reference_year, 12, 31)
    end
    if MONTHS[period] then
      return month_end_on_or_after(reference_date, MONTHS[period])
    end
    return nil
  end
  if value == "this month" then
    local _, reference_month = parse_iso_date(reference_date)
    return last_day_of_month(reference_year, reference_month)
  end
  if value == "this year" then
    return format_date(reference_year, 12, 31)
  end

  if value == "new year's day" or value == "new years day" then
    return month_day_on_or_after(reference_date, 1, 1, nil)
  end
  local leap_year = value:match("^leap day (%d%d%d%d)$")
  if leap_year or value == "leap day" then
    return month_day_on_or_after(reference_date, 2, 29, tonumber(leap_year))
  end

  local left, right = value:match("^(.-) of (%a+)$")
  if left then
    local day = day_number(left)
    if day and MONTHS[right] then
      return month_day_on_or_after(reference_date, MONTHS[right], day, nil)
    end
    if day and right == "month" then
      return day_of_month_on_or_after(reference_date, day, false)
    end
    return nil
  end

  local named = month_phrase(value, reference_date)
  if named then
    return named
  end

  local ordinal = ordinal_day(value)
  if ordinal then
    return day_of_month_on_or_after(reference_date, ordinal, false)
  end

  return nil
end

-- Times of day carry no date of their own: they pin the task to the reference
-- day, and an explicit DATE phrase in the same input overrides them. todo.txt
-- has no time field, so the phrase itself is not preserved.
local TIME_PHRASES = {
  morning = true,
  noon = true,
  midday = true,
  afternoon = true,
  evening = true,
  tonight = true,
  night = true,
  midnight = true,
}

-- The qualifiers a time of day collects. None of them move it off the
-- reference day, so "sometime this morning" and "morning" are one phrase.
local TIME_LEAD_WORDS = {
  around = true,
  at = true,
  before = true,
  by = true,
  ["in"] = true,
  on = true,
  sometime = true,
  the = true,
  this = true,
}

local HOUR_WORDS = {
  one = 1,
  two = 2,
  three = 3,
  four = 4,
  five = 5,
  six = 6,
  seven = 7,
  eight = 8,
  nine = 9,
  ten = 10,
  eleven = 11,
  twelve = 12,
}

local function clock_reading(value)
  local hour, minute = value:match("^(%d%d?):(%d%d) ?[ap]?m?$")
  if not hour then
    hour, minute = value:match("^(%d%d?) ?[ap]m$"), "0"
  end
  if hour then
    hour, minute = tonumber(hour), tonumber(minute)
    return hour <= 23 and minute <= 59
  end
  -- Spoken clock readings name the minutes before the hour.
  local spoken = value:match("^half past (%w+)$")
    or value:match("^quarter past (%w+)$")
    or value:match("^quarter to (%w+)$")
    or value:match("^(%w+) o'clock$")
  if spoken then
    return (HOUR_WORDS[spoken] or tonumber(spoken:match("^(%d%d?)$"))) ~= nil
  end
  return false
end

local function resolve_time(raw, reference_date)
  if not parse_iso_date(reference_date) then
    return nil
  end
  local value = trim(raw):lower():gsub("%s+", " ")
  value = strip_lead(trim(value), TIME_LEAD_WORDS)
  if TIME_PHRASES[value] or clock_reading(value) then
    return reference_date
  end
  return nil
end

local function metadata_value(raw, sigil)
  local value = trim(raw)
  local explicit = value:sub(1, 1) == sigil
  if explicit then
    value = value:sub(2)
  end
  if value == "" or value:find("[%s%c]") or value:sub(1, 1):match("[+@]") then
    return nil, explicit
  end
  return value, explicit
end

local function unique_insert(values, seen, value)
  local key = value:lower()
  if not seen[key] then
    seen[key] = true
    values[#values + 1] = value
  end
end

local function inventory_set(values)
  if type(values) ~= "table" or #values > 16 then
    return nil
  end
  local set = {}
  for _, value in ipairs(values) do
    if type(value) ~= "string"
        or value == ""
        or #value > 64
        or value:find("[%s%c]")
        or value:sub(1, 1):match("[+@]") then
      return nil
    end
    local key = value:lower()
    if set[key] then
      return nil
    end
    set[key] = true
  end
  return set
end

local function gap_is_safe(value)
  local normalized = value:lower()
  for _, punctuation in ipairs(GAP_PUNCTUATION) do
    normalized = normalized:gsub(punctuation, " ")
  end
  if normalized:find("[^%w%s,;:%.%-]") then
    return false
  end
  normalized = normalized:gsub("[,;:%.%-]", " ")
  for word in normalized:gmatch("%S+") do
    if not GAP_WORDS[word] then
      return false
    end
  end
  return true
end

-- Validates the structured recurrence head and renders its todo.txt value.
-- Strictness is the difference between `rec:1w` (a week after the task is
-- completed) and `rec:+1w` (a week after its due date), so the model states it
-- and this module never infers it from the phrase.
-- Each field of the head carries its own confidence, so each is thresholded on
-- its own: a series whose interval is certain and whose anchor is a guess is
-- not a series anyone should be given.
local function confident_value(field)
  if type(field) ~= "table"
      or not is_confidence(field.confidence)
      or field.confidence < RECURRENCE_CONFIDENCE then
    return nil
  end
  return field.value
end

local function normalize_recurrence(recurrence)
  if type(recurrence) ~= "table" then
    return nil
  end
  local interval = confident_value(recurrence.interval)
  local unit = confident_value(recurrence.unit)
  local strict = confident_value(recurrence.strict)
  if not is_integer(interval)
      or interval < 1
      or interval > MAX_INTERVAL
      or type(unit) ~= "string"
      or not RECURRENCE_UNITS[unit]
      or type(strict) ~= "boolean" then
    return nil
  end
  local anchor = recurrence.anchor
  if anchor ~= nil then
    local value = confident_value(anchor)
    if not is_integer(value) then
      return nil
    end
    if anchor.kind == "weekday" then
      if value > 6 then
        return nil
      end
    elseif anchor.kind == "day_of_month" then
      if value < 1 or value > 31 then
        return nil
      end
    else
      return nil
    end
    anchor = { kind = anchor.kind, value = value }
  end
  return {
    anchor = anchor,
    value = (strict and "+" or "") .. tostring(interval) .. unit,
  }
end

-- An anchor names the day the series lands on, so today counts as its first
-- occurrence.
local function anchor_date(anchor, reference_date)
  if anchor.kind == "weekday" then
    return weekday_on_or_after(reference_date, anchor.value, true)
  end
  return day_of_month_on_or_after(reference_date, anchor.value, true)
end

function policy.propose(result, context)
  if type(result) ~= "table"
      or result.schema_version ~= 1
      or type(result.input) ~= "table"
      or type(result.input.text) ~= "string"
      or type(result.prediction) ~= "table"
      or type(result.prediction.outcome) ~= "table" then
    return verdict("clarify", "INVALID_RESULT", "The parser returned an invalid result.")
  end
  if type(context) ~= "table" or type(context.reference_date) ~= "string"
      or not parse_iso_date(context.reference_date) then
    return verdict("clarify", "INVALID_CONTEXT", "A valid reference date is required.")
  end

  local outcome = result.prediction.outcome
  if not is_confidence(outcome.confidence) then
    return verdict("clarify", "INVALID_RESULT", "The parser returned invalid confidence.")
  end
  if outcome.label == "cancel" then
    return verdict("cancel", "CANCELLED", "No task was drafted.")
  end
  if outcome.label ~= "parsed" then
    local messages = {
      clarify = "Please clarify the task.",
      unsupported = "That request is not supported yet.",
      multiple = "Please add one task at a time.",
    }
    return verdict(
      "clarify",
      "MODEL_" .. tostring(outcome.label):upper(),
      messages[outcome.label] or "The request could not be parsed safely."
    )
  end
  if outcome.confidence < OUTCOME_CONFIDENCE then
    return verdict("clarify", "LOW_OUTCOME_CONFIDENCE", "Please clarify the task.")
  end

  local evidence = result.prediction.evidence
  if type(evidence) ~= "table" or #evidence > MAX_EVIDENCE then
    return verdict("clarify", "INVALID_EVIDENCE", "The parser returned invalid evidence.")
  end
  local existing = result.input.existing
  if type(existing) ~= "table" then
    return verdict("clarify", "INVALID_RESULT", "The parser returned invalid inventories.")
  end
  local project_inventory = inventory_set(existing.projects)
  local context_inventory = inventory_set(existing.contexts)
  if not project_inventory or not context_inventory then
    return verdict("clarify", "INVALID_RESULT", "The parser returned invalid inventories.")
  end

  local source = result.input.text
  local previous_end = 0
  local task_text, projects, contexts = {}, {}, {}
  local project_seen, context_seen = {}, {}
  local due, day_of, recurrence_span = nil, nil, false
  local said_task, deferred_time = false, {}

  for _, span in ipairs(evidence) do
    if type(span) ~= "table"
        or not LABELS[span.label]
        or not is_integer(span.start)
        or not is_integer(span["end"])
        or span.start < previous_end
        or span["end"] <= span.start
        or span["end"] > #source
        or type(span.text) ~= "string"
        or source:sub(span.start + 1, span["end"]) ~= span.text
        or not is_confidence(span.confidence) then
      return verdict("clarify", "INVALID_EVIDENCE", "Please clarify the task details.")
    end
    if span.confidence < FIELD_CONFIDENCE then
      return verdict("clarify", "INVALID_EVIDENCE", "Please clarify the task details.")
    end
    local span_label = span.label
    if not gap_is_safe(source:sub(previous_end + 1, span.start)) then
      return verdict("clarify", "UNEXPLAINED_TEXT", "Please clarify the complete task.")
    end
    previous_end = span["end"]

    if span_label == "TASK" then
      task_text[#task_text + 1] = trim(span.text)
      said_task = true
    elseif span_label == "PROJECT" or span_label == "CONTEXT" then
      local sigil = span_label == "PROJECT" and "+" or "@"
      local value, explicit = metadata_value(span.text, sigil)
      if not value then
        return verdict("clarify", "INVALID_METADATA", "Please clarify the project or context.")
      end
      local inventory = span_label == "PROJECT" and project_inventory or context_inventory
      local matches_existing = inventory[value:lower()] == true
      if span.matches_existing ~= matches_existing then
        return verdict("clarify", "INVALID_EVIDENCE", "The parser returned inconsistent metadata.")
      end
      if not matches_existing and not explicit then
        return verdict(
          "clarify",
          "AMBIGUOUS_NEW_METADATA",
          "Use +" .. value .. " or @" .. value .. " to add new metadata explicitly."
        )
      end
      if span_label == "PROJECT" then
        unique_insert(projects, project_seen, value)
      else
        unique_insert(contexts, context_seen, value)
      end
    elseif span_label == "DATE" then
      local resolved = resolve_date(span.text, context.reference_date)
      if not resolved or (due and due ~= resolved) then
        return verdict("clarify", "AMBIGUOUS_DATE", "Please provide one unambiguous due date.")
      end
      due = resolved
    elseif span_label == "TIME" then
      local resolved = resolve_time(span.text, context.reference_date)
      if not resolved or (day_of and day_of ~= resolved) then
        return verdict("clarify", "AMBIGUOUS_TIME", "Please provide one unambiguous time.")
      end
      day_of = resolved
      -- `due:` records the day, and todo.txt has no field for the hour, so the
      -- phrase stays in the title rather than being dropped on the floor. It
      -- keeps the place it was said in, except when it was said before the
      -- task — "remind me at noon to call amy" is a task called "call amy at
      -- noon", not one called "at noon call amy".
      if said_task then
        task_text[#task_text + 1] = trim(span.text)
      else
        deferred_time[#deferred_time + 1] = trim(span.text)
      end
    elseif span_label == "RECURRENCE" then
      recurrence_span = true
    end
  end
  if not gap_is_safe(source:sub(previous_end + 1)) then
    return verdict("clarify", "UNEXPLAINED_TEXT", "Please clarify the complete task.")
  end

  for _, value in ipairs(deferred_time) do
    task_text[#task_text + 1] = value
  end
  local title = trim(table.concat(task_text, " "))
  if not said_task or title == "" then
    return verdict("clarify", "MISSING_TASK", "Please say what the task is.")
  end

  local priority = result.prediction.priority
  local priority_label = nil
  if priority ~= nil then
    if type(priority) ~= "table"
        or not is_confidence(priority.confidence)
        or priority.confidence < PRIORITY_CONFIDENCE
        or (priority.label ~= nil
          and (type(priority.label) ~= "string"
            or not priority.label:match("^[A-Z]$"))) then
      return verdict("clarify", "INVALID_PRIORITY", "Please clarify the task priority.")
    end
    priority_label = priority.label
  end

  -- The structured head and the evidence span have to agree: a recurrence with
  -- no phrase behind it, or a phrase with no structure, is not evidence.
  local recurrence = nil
  if result.prediction.recurrence ~= nil or recurrence_span then
    recurrence = normalize_recurrence(result.prediction.recurrence)
    if not recurrence or not recurrence_span then
      return verdict(
        "clarify",
        "INVALID_RECURRENCE",
        "Please clarify how often the task repeats."
      )
    end
  end

  -- A date phrase outranks a time of day, and both outrank the day the
  -- recurrence anchor first lands on.
  due = due or day_of
  if not due and recurrence and recurrence.anchor then
    due = anchor_date(recurrence.anchor, context.reference_date)
    if not due then
      return verdict(
        "clarify",
        "INVALID_RECURRENCE",
        "Please clarify when the task first repeats."
      )
    end
  end

  -- The parts tile the line and the host concatenates them, so every part after
  -- the first brings the space that separates it.
  local parts = { { kind = "text", text = title } }
  local function add(part)
    parts[#parts + 1] = { kind = "space" }
    parts[#parts + 1] = part
  end
  for _, value in ipairs(projects) do
    add({ kind = "project", value = value })
  end
  for _, value in ipairs(contexts) do
    add({ kind = "context", value = value })
  end
  if due then
    add({ kind = "tag", key = "due", value = due })
  end
  if recurrence then
    add({ kind = "tag", key = "rec", value = recurrence.value })
  end

  return {
    status = "draft",
    spec = {
      prefix = { priority = priority_label },
      parts = parts,
    },
  }
end

local JSON_NULL = {}
local MAX_INPUT_BYTES = 160
local MAX_RESULT_BYTES = 64 * 1024
local MAX_INVENTORY_ENTRIES = 16
local MAX_INVENTORY_BYTES = 256
local MODEL_METADATA =
  '{"schema_version":1,"model_version":"todo-ai-tiny-conv-0.3.0",' ..
  '"weights_sha256":"13f74aefe01f8f401aaaf37344dc67247a828376a3896945ab21b3e6d02fbbbf"}'

local function json_error()
  error("invalid JSON", 0)
end

local function utf8_character(codepoint)
  if codepoint <= 0x7f then
    return string.char(codepoint)
  end
  if codepoint <= 0x7ff then
    return string.char(
      0xc0 + math.floor(codepoint / 0x40),
      0x80 + codepoint % 0x40
    )
  end
  if codepoint <= 0xffff then
    return string.char(
      0xe0 + math.floor(codepoint / 0x1000),
      0x80 + math.floor(codepoint / 0x40) % 0x40,
      0x80 + codepoint % 0x40
    )
  end
  if codepoint <= 0x10ffff then
    return string.char(
      0xf0 + math.floor(codepoint / 0x40000),
      0x80 + math.floor(codepoint / 0x1000) % 0x40,
      0x80 + math.floor(codepoint / 0x40) % 0x40,
      0x80 + codepoint % 0x40
    )
  end
  json_error()
end

local function json_decode(source)
  if type(source) ~= "string" or #source > MAX_RESULT_BYTES then
    json_error()
  end
  local position = 1

  local function skip_space()
    local _, finish = source:find("^[ \t\r\n]*", position)
    position = (finish or position - 1) + 1
  end

  local function hexadecimal(count)
    local value = source:sub(position, position + count - 1)
    if #value ~= count or not value:match("^%x+$") then
      json_error()
    end
    position = position + count
    return tonumber(value, 16)
  end

  local function parse_string()
    if source:sub(position, position) ~= '"' then
      json_error()
    end
    position = position + 1
    local output = {}
    while position <= #source do
      local character = source:sub(position, position)
      position = position + 1
      if character == '"' then
        return table.concat(output)
      end
      if character == "\\" then
        local escape = source:sub(position, position)
        position = position + 1
        local simple = {
          ['"'] = '"',
          ["\\"] = "\\",
          ["/"] = "/",
          b = "\b",
          f = "\f",
          n = "\n",
          r = "\r",
          t = "\t",
        }
        if simple[escape] then
          output[#output + 1] = simple[escape]
        elseif escape == "u" then
          local codepoint = hexadecimal(4)
          if codepoint >= 0xd800 and codepoint <= 0xdbff then
            if source:sub(position, position + 1) ~= "\\u" then
              json_error()
            end
            position = position + 2
            local low = hexadecimal(4)
            if low < 0xdc00 or low > 0xdfff then
              json_error()
            end
            codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + low - 0xdc00
          elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
            json_error()
          end
          output[#output + 1] = utf8_character(codepoint)
        else
          json_error()
        end
      else
        if character:byte() < 0x20 then
          json_error()
        end
        output[#output + 1] = character
      end
    end
    json_error()
  end

  local function parse_number()
    local start = position
    if source:sub(position, position) == "-" then
      position = position + 1
    end
    local first = source:sub(position, position)
    if first == "0" then
      position = position + 1
      if source:sub(position, position):match("%d") then
        json_error()
      end
    elseif first:match("[1-9]") then
      repeat
        position = position + 1
      until not source:sub(position, position):match("%d")
    else
      json_error()
    end
    if source:sub(position, position) == "." then
      position = position + 1
      if not source:sub(position, position):match("%d") then
        json_error()
      end
      repeat
        position = position + 1
      until not source:sub(position, position):match("%d")
    end
    local exponent = source:sub(position, position)
    if exponent == "e" or exponent == "E" then
      position = position + 1
      local sign = source:sub(position, position)
      if sign == "+" or sign == "-" then
        position = position + 1
      end
      if not source:sub(position, position):match("%d") then
        json_error()
      end
      repeat
        position = position + 1
      until not source:sub(position, position):match("%d")
    end
    local number = tonumber(source:sub(start, position - 1))
    if not number then
      json_error()
    end
    return number
  end

  local parse_value
  parse_value = function(depth)
    if depth > 32 then
      json_error()
    end
    skip_space()
    local character = source:sub(position, position)
    if character == '"' then
      return parse_string()
    end
    if character == "{" then
      position = position + 1
      local object = {}
      local seen_keys = {}
      skip_space()
      if source:sub(position, position) == "}" then
        position = position + 1
        return object
      end
      while true do
        skip_space()
        local key = parse_string()
        if seen_keys[key] then
          json_error()
        end
        seen_keys[key] = true
        skip_space()
        if source:sub(position, position) ~= ":" then
          json_error()
        end
        position = position + 1
        local value = parse_value(depth + 1)
        if value ~= JSON_NULL then
          object[key] = value
        end
        skip_space()
        local separator = source:sub(position, position)
        position = position + 1
        if separator == "}" then
          return object
        end
        if separator ~= "," then
          json_error()
        end
      end
    end
    if character == "[" then
      position = position + 1
      local array = {}
      skip_space()
      if source:sub(position, position) == "]" then
        position = position + 1
        return array
      end
      while true do
        local value = parse_value(depth + 1)
        array[#array + 1] = value
        skip_space()
        local separator = source:sub(position, position)
        position = position + 1
        if separator == "]" then
          return array
        end
        if separator ~= "," then
          json_error()
        end
      end
    end
    if source:sub(position, position + 3) == "true" then
      position = position + 4
      return true
    end
    if source:sub(position, position + 4) == "false" then
      position = position + 5
      return false
    end
    if source:sub(position, position + 3) == "null" then
      position = position + 4
      return JSON_NULL
    end
    return parse_number()
  end

  local value = parse_value(0)
  skip_space()
  if position <= #source or value == JSON_NULL then
    json_error()
  end
  return value
end

local function json_string(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    local escapes = {
      ['"'] = '\\"',
      ["\\"] = "\\\\",
      ["\b"] = "\\b",
      ["\f"] = "\\f",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
    }
    return escapes[character] or ("\\u%04x"):format(character:byte())
  end) .. '"'
end

local function json_array(values)
  local output = {}
  for index, value in ipairs(values) do
    output[index] = json_string(value)
  end
  return "[" .. table.concat(output, ",") .. "]"
end

local function collect_inventory(field)
  local candidates, seen = {}, {}
  for _, current_task in ipairs(taskle.tasks()) do
    for _, value in ipairs(current_task[field]) do
      if type(value) == "string"
          and value ~= ""
          and #value <= 64
          and not value:find("[%s%c]")
          and not value:match("^[+@]") then
        local folded = value:lower()
        if not seen[folded] then
          seen[folded] = true
          candidates[#candidates + 1] = value
        end
      end
    end
  end
  table.sort(candidates, function(left, right)
    local left_folded, right_folded = left:lower(), right:lower()
    return left_folded == right_folded and left < right or left_folded < right_folded
  end)

  local output, encoded_bytes = {}, 0
  for _, value in ipairs(candidates) do
    local added = #value + 1 + (#output > 0 and 1 or 0)
    if #output < MAX_INVENTORY_ENTRIES
        and encoded_bytes + added <= MAX_INVENTORY_BYTES then
      output[#output + 1] = value
      encoded_bytes = encoded_bytes + added
    end
  end
  return output
end

local function arrays_equal(left, right)
  if type(left) ~= "table" or #left ~= #right then
    return false
  end
  for index, value in ipairs(right) do
    if left[index] ~= value then
      return false
    end
  end
  return true
end

local runtime_handle = nil
local pending_draft = nil
local state = { message = "", status = "" }
local USER_ERROR = {}
local RUNTIME_ERROR = "The task could not be parsed safely. Please try again."

local function user_error(message)
  error({ kind = USER_ERROR, message = message }, 0)
end

local function readiness()
  if type(taskle.supports) ~= "function"
      or not taskle.supports("tasks")
      or not taskle.supports("resource")
      or not taskle.supports("wasm") then
    return nil, "This Taskle version does not provide the required plugin APIs."
  end
  local draft = type(taskle.task) == "table"
    and type(taskle.task.draft) == "function"
  if not draft then
    return nil, "This Taskle version does not support task drafts."
  end
  if type(taskle.has) ~= "function" or not taskle.has("wasm") then
    return nil, "The plugin does not have its requested WASM permission."
  end
  return true
end

local function ensure_runtime()
  if runtime_handle then
    return runtime_handle
  end
  local model = taskle.resource.read("model")
  local handle = taskle.wasm.load("runtime")
  taskle.wasm.call(handle, "initialize", MODEL_METADATA .. "\n" .. model)
  runtime_handle = handle
  return handle
end

local function inference_request(message, projects, contexts)
  return '{"schema_version":1,"text":' .. json_string(message) ..
    ',"existing":{"projects":' .. json_array(projects) ..
    ',"contexts":' .. json_array(contexts) .. "}}"
end

-- `!a`..`!c` at the end of the line sets the priority outright, the same marker
-- Quick Add accepts, so the two entry points read a typed priority alike. It is
-- taken off before inference rather than sent through it: the model never sees
-- a token it was not trained on, the evidence it returns still accounts for
-- every word it was given, and a priority the user stated outranks a predicted
-- one. Text that is nothing but the marker is left alone -- there would be no
-- task left behind it.
local function take_priority(text)
  local rest, letter = text:match("^(.-)%s+!([abcABC])$")
  if rest and rest:match("%S") then
    return rest, letter:upper()
  end
  return text, nil
end

local function infer(message)
  local ready, reason = readiness()
  if not ready then
    user_error(reason)
  end
  if type(message) ~= "string" or message:match("^%s*$") then
    user_error("Enter one task.")
  end
  if #message > MAX_INPUT_BYTES or message:find("[%z\1-\31\127]") then
    user_error("The task must be at most 160 UTF-8 bytes without control characters.")
  end

  -- The byte and control-character limits above apply to what the user typed;
  -- the marker comes off afterwards so the same input is accepted or refused
  -- whether or not it carries one.
  local text, priority = take_priority(message)

  local projects = collect_inventory("projects")
  local contexts = collect_inventory("contexts")
  local request = inference_request(text, projects, contexts)
  local output = taskle.wasm.call(ensure_runtime(), "parse", request)
  local result = json_decode(output)
  if type(result) ~= "table"
      or type(result.input) ~= "table"
      or result.input.text ~= text
      or type(result.input.existing) ~= "table"
      or not arrays_equal(result.input.existing.projects, projects)
      or not arrays_equal(result.input.existing.contexts, contexts) then
    error("The parser returned inconsistent input evidence.", 0)
  end
  local context = {
    reference_date = taskle.today(),
    timezone = taskle.timezone,
    locale = taskle.locale,
  }
  local proposal = policy.propose(result, context)
  if priority and proposal.status == "draft" then
    proposal.spec.prefix = proposal.spec.prefix or {}
    proposal.spec.prefix.priority = priority
  end
  return proposal
end

local function reset_runtime()
  if runtime_handle then
    pcall(taskle.wasm.unload, runtime_handle)
    runtime_handle = nil
  end
end

local function propose_message()
  local ok, proposal = pcall(infer, state.message)
  if not ok then
    if type(proposal) == "table" and proposal.kind == USER_ERROR then
      state.status = proposal.message
      return
    end
    reset_runtime()
    state.status = RUNTIME_ERROR
    return
  end
  state.status = proposal.message or ""
  if proposal.status == "draft" then
    pending_draft = proposal.spec
    taskle.run("todo-ai.draft")
    state.status = "Opening the standard task editor…"
  end
end

-- Quick Add is the primary entry point. Returning nil is deliberately
-- fail-open: Taskle continues through its unchanged creation path with the
-- exact raw text the user submitted.
local function preprocess_task(message)
  local ok, proposal = pcall(infer, message)
  if not ok then
    reset_runtime()
    return nil
  end
  if proposal.status == "draft" then
    return proposal.spec
  end
  return nil
end

local function view()
  local ready, reason = readiness()
  local rows = {
    taskle.ui.text { "Add a task from natural language", tone = "heading" },
    taskle.ui.text {
      "The parser proposes a draft. Nothing is added until you save it.",
      tone = "dim",
    },
    taskle.ui.text_input {
      id = "message",
      placeholder = "Submit the report tomorrow +work",
      value = state.message,
      on_input = "message",
    },
    taskle.ui.button {
      "Parse task",
      on_press = ready and state.message ~= "" and "parse" or nil,
      style = "primary",
    },
  }
  local status = state.status ~= "" and state.status or reason
  if status then
    rows[#rows + 1] = taskle.ui.separator {}
    rows[#rows + 1] = taskle.ui.text { status, tone = "accent" }
  end
  rows.spacing = 8
  return taskle.ui.column(rows)
end

local function update(_, message, value)
  if message == "message" then
    state.message = value or ""
    state.status = ""
  elseif message == "parse" then
    propose_message()
  end
end

if type(taskle) == "table" then
  if type(taskle.task) == "table"
      and type(taskle.task.preprocess) == "function" then
    taskle.task.preprocess(preprocess_task)
  end
  taskle.command {
    name = "todo-ai.draft",
    title = "Review parsed task",
    fn = function()
      if not pending_draft then
        return "Parse a task before opening a draft."
      end
      local draft = pending_draft
      pending_draft = nil
      taskle.task.draft(draft)
      return "Review the parsed task and save it to add it."
    end,
  }
  taskle.window {
    id = "todo-ai",
    title = "Add with AI",
    command = "todo-ai.open",
    view = view,
    update = update,
  }
  taskle.menu {
    title = "Add with AI…",
    command = "todo-ai.open",
    menu = "Task",
  }
end

return policy
