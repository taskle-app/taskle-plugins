-- quick-add: type a task the way you would say it.
--
--   pay rent every month            → pay rent rec:1m due:<the 1st>
--   call mom tomorrow               → call mom due:<tomorrow>
--   review notes next friday !a     → (A) review notes due:<friday>
--   book flights in 3 weeks         → book flights due:<+21d>
--   file taxes by the end of month  → file taxes due:<last of month>
--
-- The app already resolves an explicit `due:tomorrow` when
-- "Convert relative dates on entry" is on. This is the other half: recognising
-- the phrase when it was never written as a tag, which is what people actually
-- type into a one-line box.
--
-- # Why `before_create` and not a command
--
-- A command would be a second way to add a task, and would miss every other
-- route — the add bar, a paste, a plugin. `before_create` sits on the one path
-- they all take, so the rule holds however the task arrived.
--
-- # What it will not do
--
-- Only phrases at the *end* of the line are consumed. "call mom tomorrow" has a
-- date; "remind me about the tomorrow deadline" does not, and guessing at the
-- middle of a sentence is how a quick-add starts eating words people meant. If
-- nothing matches, the line is left exactly as typed.
--
-- Nor does it read a repetition that todo.txt cannot state. "every 3rd monday"
-- is either the third Monday of a month or one week in three depending on who
-- is saying it, and `rec:` records neither reading faithfully.

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

-- Repetitions said as a single word, in todo.txt's `rec:` vocabulary.
local ADVERBS = {
  daily = "1d",
  nightly = "1d",
  weekly = "1w",
  biweekly = "2w",
  fortnightly = "2w",
  monthly = "1m",
  quarterly = "3m",
  yearly = "1y",
  annually = "1y",
}

-- Units, singular and plural, as `rec:` letters.
local UNITS = {
  day = "d",
  days = "d",
  week = "w",
  weeks = "w",
  month = "m",
  months = "m",
  year = "y",
  years = "y",
}

local ORDINAL_SUFFIXES = { st = true, nd = true, rd = true, th = true }

local function ordinal_day(value)
  local digits, suffix = value:match("^(%d%d?)(%a%a)$")
  if not digits or not ORDINAL_SUFFIXES[suffix] then
    return nil
  end
  return tonumber(digits)
end

local function whole_number(value)
  local digits = value:match("^(%d+)$")
  if digits then
    return tonumber(digits)
  end
  return NUMBER_WORDS[value]
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

local function format_date(year, month, day)
  return ("%04d-%02d-%02d"):format(year, month, day)
end

local function parse_date(value)
  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return nil
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if month < 1 or month > 12 or day < 1 or day > days_in_month(year, month) then
    return nil
  end
  return year, month, day
end

-- Calendar months, not thirty days. "next month" on the 31st lands on the last
-- day of a shorter month rather than sliding into the one after it.
local function add_months(iso, count)
  local year, month, day = parse_date(iso)
  if not year then
    return nil
  end
  local index = year * 12 + (month - 1) + count
  year = math.floor(index / 12)
  month = index % 12 + 1
  return format_date(year, month, math.min(day, days_in_month(year, month)))
end

local function day_of_week(iso)
  local year, month, day = parse_date(iso)
  if not year then
    return nil
  end
  -- Zeller-style day-of-week, so this needs no date library.
  local shift = math.floor((14 - month) / 12)
  local adjusted_year = year - shift
  local adjusted_month = month + 12 * shift - 2
  return (
    day
    + adjusted_year
    + math.floor(adjusted_year / 4)
    - math.floor(adjusted_year / 100)
    + math.floor(adjusted_year / 400)
    + math.floor((31 * adjusted_month) / 12)
  ) % 7
end

-- Days from today to the next named weekday. Always forward and never today:
-- "next friday" said on a Friday means the one coming, not the one you are in.
local function days_to_weekday(name)
  local target = WEEKDAYS[name]
  if not target then
    return nil
  end
  local ahead = (target - day_of_week(taskle.today())) % 7
  return ahead == 0 and 7 or ahead
end

local function weekday_date(name)
  local ahead = days_to_weekday(name)
  return ahead and taskle.today(ahead) or nil
end

-- The next time that day of the month comes round. A month without a 31st is
-- skipped rather than rewritten to its last day: the user named a day.
local function day_of_month_date(target)
  if not target or target < 1 or target > 31 then
    return nil
  end
  local year, month, day = parse_date(taskle.today())
  for step = (target > day) and 0 or 1, 12 do
    local candidate = add_months(format_date(year, month, 1), step)
    local candidate_year, candidate_month = parse_date(candidate)
    if target <= days_in_month(candidate_year, candidate_month) then
      return format_date(candidate_year, candidate_month, target)
    end
  end
  return nil
end

-- A month named without a year means the next one that has not gone past.
local function month_day_date(month, day, year)
  if not month or not day or day < 1 then
    return nil
  end
  local today = taskle.today()
  local reference_year = parse_date(today)
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
      if candidate >= today then
        return candidate
      end
    end
  end
  return nil
end

local function end_of_month_date()
  local year, month = parse_date(taskle.today())
  return format_date(year, month, days_in_month(year, month))
end

-- Named periods close on their last day: a week on Sunday, a year on the 31st.
local function period_end_date(period)
  if period == "day" or period == "today" then
    return taskle.today()
  end
  if period == "week" then
    return weekday_date("sunday")
  end
  if period == "month" then
    return end_of_month_date()
  end
  if period == "year" then
    return format_date(parse_date(taskle.today()), 12, 31)
  end
  return nil
end

local ONE_WORD_DATES = {
  today = 0,
  tonight = 0,
  tomorrow = 1,
}

-- What a trailing phrase means as a due date, or nothing. A branch that does
-- not recognise its words declines so the caller can try a shorter phrase, and
-- the line survives untouched when none of them match.
local function date_meaning(phrase)
  local offset = ONE_WORD_DATES[phrase]
  if offset then
    return taskle.today(offset)
  end
  if phrase == "this evening" then
    return taskle.today()
  end
  if parse_date(phrase) then
    return phrase
  end

  local period = phrase:match("^end of the (%a+)$")
    or phrase:match("^end of (%a+)$")
    or phrase:match("^(%a+) end$")
    or phrase:match("^this (%a+) ends$")
  if period then
    return period_end_date(period)
  end

  -- Words that qualify a phrase without moving the day it names.
  local rest = phrase:match("^by (.+)$")
    or phrase:match("^before (.+)$")
    or phrase:match("^on (.+)$")
    or phrase:match("^over (.+)$")
    or phrase:match("^the (.+)$")
  if rest then
    return date_meaning(rest)
  end

  if phrase == "day after tomorrow" then
    return taskle.today(2)
  end
  if phrase == "weekend" or phrase == "this weekend" or phrase == "next weekend" then
    return weekday_date("saturday")
  end
  if phrase == "this month" then
    return end_of_month_date()
  end

  local named = phrase:match("^next (%a+)$")
    or phrase:match("^this (%a+)$")
    or phrase:match("^(%a+)$")
  if named and WEEKDAYS[named] then
    return weekday_date(named)
  end
  local following = phrase:match("^next (%a+)$")
  if following and UNITS[following] then
    local unit = UNITS[following]
    if unit == "d" then
      return taskle.today(1)
    end
    if unit == "w" then
      return taskle.today(7)
    end
    return add_months(taskle.today(), unit == "m" and 1 or 12)
  end

  local count, unit = phrase:match("^in (%S+) (%a+)$")
  if not count then
    count, unit = phrase:match("^(%S+) (%a+) from now$")
  end
  if count and UNITS[unit] then
    count, unit = whole_number(count), UNITS[unit]
    if not count or count < 1 then
      return nil
    end
    if unit == "d" then
      return taskle.today(count)
    end
    if unit == "w" then
      return taskle.today(count * 7)
    end
    return add_months(taskle.today(), unit == "m" and count or count * 12)
  end

  local left, right = phrase:match("^(%S+) of the (%a+)$")
  if not left then
    left, right = phrase:match("^(%S+) of (%a+)$")
  end
  if left then
    local day = ordinal_day(left)
    if day and right == "month" then
      return day_of_month_date(day)
    end
    if day and MONTHS[right] then
      return month_day_date(MONTHS[right], day, nil)
    end
    return nil
  end

  -- A month name beside a day, in either order: "August 1", "1 Aug".
  local first, second = phrase:match("^(%S+) (%S+)$")
  if first then
    local day = tonumber(second:match("^(%d%d?)$")) or ordinal_day(second)
    if MONTHS[first] and day then
      return month_day_date(MONTHS[first], day, nil)
    end
    day = tonumber(first:match("^(%d%d?)$")) or ordinal_day(first)
    if MONTHS[second] and day then
      return month_day_date(MONTHS[second], day, nil)
    end
  end

  return day_of_month_date(ordinal_day(phrase))
end

-- What a trailing phrase means as a repetition. A series that names the day it
-- lands on gets that day as its first due date.
local function recurrence_meaning(phrase)
  local adverb = ADVERBS[phrase]
  if adverb then
    return { rec = adverb, due = taskle.today() }
  end

  local rest = phrase:match("^every (.+)$") or phrase:match("^each (.+)$")
  if not rest then
    return nil
  end

  -- Periods with no unit letter of their own.
  if rest == "fortnight" then
    return { rec = "2w", due = taskle.today() }
  end
  if rest == "quarter" then
    return { rec = "3m", due = taskle.today() }
  end
  -- Business days are todo.txt's `b` unit rather than a count of days.
  if rest == "business day" or rest == "weekday" then
    return { rec = "1b", due = taskle.today() }
  end
  local business = rest:match("^(%S+) business days?$")
  if business then
    local count = whole_number(business)
    return count and { rec = count .. "b", due = taskle.today() } or nil
  end

  if WEEKDAYS[rest] then
    return { rec = "1w", due = weekday_date(rest) }
  end
  local alternate = rest:match("^other (%a+)$")
  if alternate and WEEKDAYS[alternate] then
    return { rec = "2w", due = weekday_date(alternate) }
  end

  local monthly = ordinal_day(rest)
  if monthly then
    return { rec = "1m", due = day_of_month_date(monthly) }
  end

  local count, unit = rest:match("^(%S+) (%a+)$")
  if not count then
    count, unit = "1", rest
  end
  if count == "other" then
    count = 2
  else
    count = whole_number(count) or ordinal_day(count)
  end
  if count and count >= 1 and UNITS[unit] then
    return { rec = count .. UNITS[unit], due = taskle.today() }
  end
  return nil
end

local function phrase_meaning(phrase)
  local recurrence = recurrence_meaning(phrase)
  if recurrence then
    return recurrence
  end
  local due = date_meaning(phrase)
  return due and { due = due } or nil
end

-- `!a`..`!c` anywhere at the end sets the priority. Short because it is typed
-- constantly, and marked so it cannot be confused with a word.
local function take_priority(text)
  local rest, letter = text:match("^(.-)%s+!([abcABC])$")
  if rest then
    return rest, letter:upper()
  end
  return text, nil
end

-- The longest phrase written here — "by the end of the month" — is six words,
-- and reading further back only invites a longer wrong guess.
local MAX_PHRASE_WORDS = 6

-- A repetition this plugin could not read, left half-eaten. "every 3rd monday"
-- ends in a weekday, and taking only that word would leave "every 3rd" sitting
-- in the title beside a due date nobody asked for.
local function dangling_repetition(head)
  local lowered = " " .. head:lower()
  return lowered:match(" every$") ~= nil
    or lowered:match(" each$") ~= nil
    or lowered:match(" every %S+$") ~= nil
    or lowered:match(" each %S+$") ~= nil
end

-- Pull one trailing phrase off `text`. Returns the shortened text and what it
-- meant, or nothing. Longest first, so "every other week" is read as a phrase
-- rather than as the word "week".
local function take_phrase(text)
  local words = {}
  for word in text:gmatch("%S+") do
    words[#words + 1] = word
  end
  for size = math.min(MAX_PHRASE_WORDS, #words), 1, -1 do
    local phrase = table.concat(words, " ", #words - size + 1):lower()
    local meaning = phrase_meaning(phrase)
    if meaning then
      local head = table.concat(words, " ", 1, #words - size)
      if dangling_repetition(head) then
        return text, nil
      end
      return head, meaning
    end
  end
  return text, nil
end

taskle.on("before_create", function(ctx)
  -- Only the plain words are considered. A `+project` or `due:` the user typed
  -- explicitly is theirs, and this must not reinterpret it.
  local task = ctx.task
  local parsed = taskle.parse(task.raw)
  local trailing_tags = {}
  local words = {}
  for _, part in ipairs(parsed.parts) do
    -- The parts tile the line, so the whitespace between them is a part of its
    -- own. This rebuilds the sentence from the words, and writes its own
    -- separators below.
    if part.kind == "text" then
      words[#words + 1] = part.text
    elseif part.kind ~= "space" then
      trailing_tags[#trailing_tags + 1] = part
    end
  end
  -- An explicit due date wins; the user said it in the format's own words.
  local has_due = task.raw:match("due:%S+") ~= nil
  local has_rec = task.raw:match("rec:%S+") ~= nil

  local text = table.concat(words, " ")
  local text, priority = take_priority(text)
  local text, phrase = take_phrase(text)
  if not priority and not phrase then
    return
  end
  if text:match("^%s*$") then
    -- The phrase was the whole task. "tomorrow" is not a task, so leave it be
    -- rather than creating an empty one with a due date.
    return
  end

  -- The host concatenates the parts it is given, so each one after the first
  -- brings the space that separates it.
  local parts = {}
  local function add(part)
    if #parts > 0 then
      parts[#parts + 1] = { kind = "space" }
    end
    parts[#parts + 1] = part
  end
  for word in text:gmatch("%S+") do
    add({ kind = "text", text = word })
  end
  for _, part in ipairs(trailing_tags) do
    add(part)
  end
  if phrase and phrase.due and not has_due then
    add({ kind = "tag", text = "due:" .. phrase.due, key = "due", value = phrase.due })
  end
  if phrase and phrase.rec and not has_rec then
    add({ kind = "tag", text = "rec:" .. phrase.rec, key = "rec", value = phrase.rec })
  end

  local prefix = parsed.prefix
  if priority then
    prefix.priority = priority
  end
  return { prefix = prefix, parts = parts }
end)
