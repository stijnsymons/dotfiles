-- fix-internal-links.lua
--
-- The typst PDF engine hard-fails on any internal link (#anchor) whose target
-- doesn't exactly match a generated heading id. Markdown authored for GitHub
-- trips this constantly: GitHub strips '.' (and other punctuation) from anchors
-- while pandoc keeps it, so a hand-written `#...-scenarios-person-mutationsmd`
-- never matches pandoc's `#...-scenarios-person-mutations.md`.
--
-- This filter reconciles the two:
--   1. collect every element id in the document (headers, divs, spans);
--   2. for each internal link, if its anchor already resolves, leave it;
--      else try to reconnect it by matching on a normalised form (lowercase,
--      keep only [a-z0-9-]) — this bridges the GitHub/pandoc punctuation gap;
--   3. if it still can't be resolved, unwrap the link to plain text so the
--      build succeeds instead of aborting on a dangling reference.

local function normalise(s)
  return select(1, s:lower():gsub('[^a-z0-9-]', ''))
end

function Pandoc(doc)
  local ids = {}        -- exact id  -> true
  local norm = {}       -- normalised id -> real id (nil if ambiguous)

  local function record(el)
    local id = el.identifier
    if id and id ~= '' then
      ids[id] = true
      local n = normalise(id)
      if norm[n] == nil then
        norm[n] = id
      elseif norm[n] ~= id then
        norm[n] = false   -- collision: two ids normalise the same, don't guess
      end
    end
  end

  doc:walk {
    Header = record,
    Div = record,
    Span = record,
  }

  return doc:walk {
    Link = function(l)
      local tgt = l.target
      if tgt:sub(1, 1) ~= '#' then return nil end   -- external / file link, leave it
      local anchor = tgt:sub(2)
      if ids[anchor] then return nil end             -- already resolves
      local hit = norm[normalise(anchor)]
      if hit then                                    -- reconnect to the real id
        l.target = '#' .. hit
        return l
      end
      return l.content                               -- dangling: keep text, drop link
    end,
  }
end
