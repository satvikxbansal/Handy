# Handy — Web Search Architecture

## The Core Tension

Handy's current flow is fast: user speaks → screenshot → Claude streams back in ~1.5-3s to first token. Adding web search risks breaking that speed. But without it, Handy can't answer "What's the latest version of SwiftData?" or "Is there a good Swift package for WebSockets?" — questions that come up constantly when you're learning a new tool.

The design challenge: **search when you need to, skip when you don't, and never make the user wait unnecessarily.**

---

## Three Architectural Patterns

### Pattern A: Claude Tool Use (Let Claude Decide)

```
User speaks
    ↓
Screenshot captured + history assembled
    ↓
Send to Claude with tool definitions:
  - web_search(query, type)
  - fetch_page(url)
  - github_search(query)
    ↓
Claude decides:
  ├── "I know this" → streams answer directly (no overhead)
  └── "I need to look this up" → emits tool_use block
        ↓
      Execute search (~500-800ms)
        ↓
      Return results to Claude
        ↓
      Claude synthesizes final answer (streams)
```

**How Claude decides:** You define tools with descriptive `description` fields. Claude reads these and uses its own judgment. The key is writing good tool descriptions that tell it *when* to use the tool, not just what it does. Example:

```json
{
  "name": "web_search",
  "description": "Search the web for current, real-time information. USE when: user asks about latest versions, recent releases, specific packages/libraries they want to find, error messages with no obvious fix, anything that might have changed after early 2025. DO NOT USE when: the question is about general UI navigation (where is a button), code review of visible code, explaining a concept you know well, or anything clearly visible on screen.",
  "input_schema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "Optimized search query. Be specific. Include version numbers, language names, framework names when relevant."
      },
      "search_type": {
        "type": "string",
        "enum": ["general", "github", "documentation"],
        "description": "general: broad web search. github: find repositories or code. documentation: find official docs or API references."
      }
    },
    "required": ["query"]
  }
}
```

Claude is already excellent at this kind of decision-making — it's fundamentally a reasoning problem, and that's what LLMs are built for. You don't need to enumerate every case. Claude understands intent.

**What happens to streaming:** When Claude decides to call a tool, the stream emits a `tool_use` content block and the `stop_reason` becomes `"tool_use"` instead of `"end_turn"`. The stream effectively pauses (keep-alive packets only). You execute the tool, send results back, and Claude resumes streaming. The user sees a brief pause — this is where your loading animation ("Searching the web...") kicks in.

**Latency impact:**
- Queries that DON'T need search: **zero overhead** (tool definitions cost ~100-200 tokens of input, negligible latency)
- Queries that DO need search: **+1.5-3s** (search API call ~500-800ms + Claude re-processing results + streaming restart)

**Verdict:** Simplest to build. Zero cost when search isn't needed. Claude's judgment is surprisingly good. The downside is that when search IS triggered, the user notices a pause.

---

### Pattern B: Router Pre-Pass (Parallel Acceleration)

```
User speaks → query text extracted
    ↓
┌──────────────────────────────────────────┐
│           PARALLEL EXECUTION             │
│                                          │
│  [Fast Classifier]    [Screenshot +      │
│   "Needs web?" ───→    Context Assembly] │
│   (~200-400ms)         (~300-500ms)      │
└──────────────┬───────────────────────────┘
               ↓
         If needs_web:
           Search API called (~500-800ms)
           (overlaps with context assembly)
               ↓
         Results injected into Claude's context
               ↓
         Claude streams answer with enriched context
```

**The Classifier:** A lightweight model (Claude Haiku at ~200ms, or a local embedding classifier at <50ms) that answers one question: *does this query need web search?*

**How the classifier works — the prompt approach (Haiku):**

```
You classify whether a user's question about software requires a web search.
Respond with JSON only: {"web": true/false, "type": "general|github|docs|none", "query": "search query or null"}

## NEEDS WEB (true):
- Recency-dependent: "latest version", "what's new in", "current", "2025", "2026", "recently released"
- Package/library discovery: "is there a library for", "best package for", "find a repo"
- Installation/setup: "how to install", "how to set up SDK", "pip install", "npm install", "SPM package"
- Error troubleshooting with specific error codes/messages
- Compatibility: "does X support Y", "is X compatible with"
- Specific API usage: "how to use the X API", "X API documentation"
- Changelog/release: "release notes", "changelog", "breaking changes"

## DOES NOT NEED WEB (false):
- UI navigation with screen visible: "where is the X button", "how do I click Y"
- General concepts: "what is a closure", "explain MVC", "how does recursion work"
- Code visible on screen: "review this code", "what does this error mean" (when error IS on screen)
- Blender/Xcode/app-specific navigation: "how to select vertices", "where is Build Settings"
- Conversation continuity: "do that again", "try a different approach", "now the next step"
```

**Concrete examples the classifier would see:**

| User Query | Classification | Reasoning |
|---|---|---|
| "What's the latest version of React Native?" | `{web: true, type: "docs", query: "React Native latest version 2026"}` | Recency-dependent — training data might be stale |
| "Is there a Swift package for markdown parsing?" | `{web: true, type: "github", query: "Swift package markdown parser SPM"}` | Package discovery — needs current ecosystem scan |
| "Where is the Add Mesh menu in Blender?" | `{web: false}` | Pure UI navigation — Claude + screenshot is enough |
| "This build is failing with error code 65" | `{web: true, type: "general", query: "Xcode build error code 65 fix"}` | Specific error code — web likely has targeted solutions |
| "Can you review this function I wrote?" | `{web: false}` | Code is on screen, no external info needed |
| "How do I add SwiftData to my Xcode project?" | `{web: true, type: "docs", query: "SwiftData setup Xcode 2026 tutorial"}` | Framework setup — instructions may have changed |
| "What does this warning mean?" (warning visible) | `{web: false}` | Visible on screen, Claude can read and explain |
| "Is Blender 4.3 out yet?" | `{web: true, type: "general", query: "Blender 4.3 release date"}` | Binary factual question about recency |

**The alternative — embedding-based classifier (<5ms):**

Pre-encode 50-100 example queries into embeddings (one set for "needs web", one set for "no web"). At runtime, embed the user's query, compute cosine similarity against both sets, route based on highest similarity. This is sub-millisecond after the initial embedding call (~30-50ms via a local model or API).

Libraries: `semantic-router` (Python) or roll your own with a small embedding model. For Swift, you could use Apple's NaturalLanguage framework for on-device embeddings.

**Latency impact:**
- Classifier adds ~200-400ms (Haiku) or ~30-50ms (embedding)
- BUT search runs in parallel with screenshot capture + context assembly
- Net result: search latency is **partially hidden** — the user might only perceive an extra ~300-500ms vs the current flow even when search IS triggered
- When search is NOT needed: **+200-400ms overhead** from the classifier (this is the tax you pay)

**Verdict:** Faster when search is needed (parallel execution). But you always pay the classifier tax, even when no search is needed. More complex to build and maintain. The classifier can also be wrong — false negatives miss searches, false positives waste time and money.

---

### Pattern C: Hybrid (Recommended)

This is what I'd actually build. It combines the best of both:

```
User speaks → query text extracted
    ↓
┌────────────────────────────────────────────────┐
│  FAST KEYWORD HEURISTIC (< 1ms, runs locally)  │
│                                                 │
│  Regex/keyword scan for high-confidence         │
│  "obviously needs web" signals:                 │
│    - "latest", "newest", "current version"      │
│    - "is there a package/library/repo for"      │
│    - "how to install/setup"                     │
│    - "v[0-9]", version number patterns          │
│    - "release notes", "changelog"               │
│    - "does X support", "compatible with"        │
│    - npm/pip/brew/spm install patterns          │
│                                                 │
│  Result: DEFINITELY_NEEDS_WEB / UNCERTAIN       │
└──────────────┬─────────────────────────────────┘
               ↓
     ┌─────────┴─────────┐
     ↓                   ↓
 DEFINITELY            UNCERTAIN
 NEEDS WEB            (most queries)
     ↓                   ↓
 Kick off search      Send to Claude WITH
 in parallel with     tool definitions
 Claude API call      (Pattern A)
     ↓                   ↓
 Results ready by     Claude decides:
 the time Claude      ├── Answer directly
 needs them           └── Call web_search tool
     ↓                        ↓
 Inject as "pre-         Execute search
 fetched context"        (user sees pause)
 into Claude call             ↓
     ↓                  Return results
 Claude streams         to Claude
 answer                      ↓
                        Claude streams
```

**Why this works:**

1. **Zero overhead for 80%+ of queries** — most questions are "where is this button" or "how do I do X in this app" which don't need web. No classifier tax. No extra latency. Pure Pattern A.

2. **Speculative pre-fetch for obvious cases** — when the heuristic is confident ("what's the latest version of X"), search starts immediately in parallel. By the time Claude processes the screenshot and decides it needs search results, they're already cached. The user barely notices.

3. **Claude handles the edge cases** — for ambiguous queries, Claude's native tool use handles the decision. It's smarter than any keyword heuristic for nuanced cases.

4. **The heuristic is dead simple to maintain** — it's just a list of regex patterns. No model to train, no embeddings to update. If it's wrong, the worst case is a wasted search call (costs $0.005) or Claude catches the miss via its own tool use.

**The keyword heuristic in Swift (pseudocode):**

```swift
enum SearchConfidence {
    case definitelyNeeds(suggestedQuery: String, type: SearchType)
    case uncertain  // let Claude decide via tool use
}

func quickSearchCheck(_ userQuery: String) -> SearchConfidence {
    let lower = userQuery.lowercased()

    // Recency signals
    let recencyPatterns = [
        "latest version", "newest version", "current version",
        "what's new in", "recently released", "just came out",
        "is .* out yet", "release notes", "changelog",
        "breaking changes in"
    ]

    // Discovery signals
    let discoveryPatterns = [
        "is there a (package|library|repo|framework|sdk|tool) for",
        "best (package|library|framework) for",
        "find a (repo|repository|package|library)",
        "alternative to", "something like"
    ]

    // Installation signals
    let installPatterns = [
        "how to (install|setup|set up|configure|add)",
        "npm install", "pip install", "brew install",
        "pod install", "swift package", "add.*dependency",
        "import.*sdk"
    ]

    // Version patterns
    let versionPatterns = [
        "v\\d+\\.\\d+", "version \\d+",
        "\\d{4} (update|release|version)"  // year-based
    ]

    // Check each category...
    // If any high-confidence pattern matches → .definitelyNeeds
    // Otherwise → .uncertain (let Claude handle via tool use)
}
```

---

## Tool Stack Recommendation

After researching every major option, here's my recommendation for Handy:

### Primary Search: Brave Search API

**Why Brave over Tavily:**
- Brave scores **higher in agentic benchmarks** (14.89 vs Tavily's 13.67) and is **~30% faster** (~600ms vs ~1000ms)
- Independent 30B+ page index — no dependency on Google/Bing
- Privacy-focused — aligns with Handy's "everything local" philosophy
- Simple REST API — trivial to call from Swift via URLSession
- Tavily was acquired by Nebius (Feb 2026) — pricing/stability uncertain

**Pricing:** $5/month base (~1,000 queries). For a personal tool, this is more than enough. Heavy usage scales to $3-5 per 1,000 queries.

**What it returns:** Title, URL, description snippet, and optionally full page content via their "Extra Snippets" or new Summarizer feature.

### Page Reading: Jina Reader API

**Why:** When you need the FULL content of a page (a GitHub README, a blog post, documentation), Brave's snippets aren't enough. Jina converts any URL into clean, LLM-ready markdown.

**How:** `GET https://r.jina.ai/{url}` — that's it. Returns clean markdown.

**Free tier:** ~200 requests/day (~6,000/month). More than enough.

**Use case in Handy:** After Brave finds relevant URLs, if Claude needs deeper content (e.g., reading a full GitHub README or a documentation page), it calls `fetch_page` which hits Jina.

### GitHub-Specific: GitHub REST API

**Why:** For "find a Swift package for X" queries, GitHub's own search is more targeted than general web search.

**How:** `GET https://api.github.com/search/repositories?q={query}+language:swift&sort=stars` — free, 10 requests/minute unauthenticated, 30/min with a token.

**Returns:** Repo name, description, stars, last updated, URL — perfect for package discovery.

### The Three-Tool Setup for Claude

```json
[
  {
    "name": "web_search",
    "description": "Search the web for current information. Use when the user asks about: latest versions or releases, how to install or set up software, finding packages/libraries/SDKs, error codes with no obvious solution, compatibility questions, or anything that might have changed after early 2025. Do NOT use for: UI navigation questions (where is a button), reviewing code visible on screen, explaining general programming concepts, or questions clearly answerable from the screenshot alone.",
    "input_schema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "The search query. Be specific — include framework names, language, version numbers when relevant."
        }
      },
      "required": ["query"]
    }
  },
  {
    "name": "fetch_page",
    "description": "Fetch and read the full content of a web page. Use after web_search when you need to read a full article, README, documentation page, or blog post that a search result pointed to. Returns clean markdown text of the page content.",
    "input_schema": {
      "type": "object",
      "properties": {
        "url": {
          "type": "string",
          "description": "The full URL of the page to read."
        }
      },
      "required": ["url"]
    }
  },
  {
    "name": "github_search",
    "description": "Search GitHub for repositories. Use when the user wants to find a library, package, SDK, or open-source tool. More targeted than web_search for code discovery. Returns top results with stars, descriptions, and last update dates.",
    "input_schema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "Search query for GitHub repositories."
        },
        "language": {
          "type": "string",
          "description": "Programming language filter (e.g., 'swift', 'python', 'javascript')."
        }
      },
      "required": ["query"]
    }
  }
]
```

---

## Implementation in Handy

### New File: `WebSearchService.swift`

Responsibilities:
- `searchBrave(query:) async throws -> [SearchResult]` — calls Brave Search API, returns top 5 results with title + snippet + URL
- `fetchPage(url:) async throws -> String` — calls Jina Reader, returns markdown content (capped at ~4000 tokens to avoid context bloat)
- `searchGitHub(query:language:) async throws -> [RepoResult]` — calls GitHub API, returns top 5 repos with name + description + stars + URL
- `speculativeSearch(query:) async -> [SearchResult]?` — the heuristic-triggered pre-fetch, stores results in a short-lived cache

### Changes to `ClaudeAPIService.swift`

- Add tool definitions to the API request body (the three tools above)
- Handle `stop_reason: "tool_use"` in the streaming parser
- When tool use is detected: extract tool name + parameters, call WebSearchService, format results, send back as `tool_result` message, resume streaming
- Support the speculative pre-fetch: if `WebSearchService` already has cached results for a matching query, return those instead of fetching again

### Changes to `HandyManager.swift`

- After extracting user's text (from voice or chat), run `quickSearchCheck()` heuristic
- If `.definitelyNeeds`: fire off `WebSearchService.speculativeSearch()` in parallel with the main Claude API call
- Add a new loading verb: "Searching the web..." for when a tool_use pause occurs
- The rest of the flow stays the same — Claude handles the decision-making

### Changes to `AppSettings.swift`

- Add `braveAPIKey` to KeychainManager.APIKeyType
- Add optional Brave API key field in Settings > Brain section
- Web search features gracefully disabled if no Brave key is configured

---

## Latency Analysis

### Current Flow (No Web Search)
```
Voice transcription:   ~500ms
Screenshot capture:    ~200ms
Context assembly:      ~100ms
Claude first token:    ~1500-2000ms
                       ─────────────
Total to first token:  ~2.3-2.8s
```

### Pattern A Only (Claude Tool Use, No Pre-fetch)
```
Same as above until Claude decides...

If NO search needed:
  Same as current:     ~2.3-2.8s  (zero overhead)

If search needed:
  Claude decides:      ~1.5-2s (emits tool_use instead of text)
  Search API call:     ~500-800ms
  Results back to Claude: ~100ms
  Claude resumes:      ~1000-1500ms to first token
                       ─────────────
  Total:               ~3.6-4.9s   (+1.3-2.1s penalty)
```

### Hybrid (Heuristic Pre-fetch + Tool Use)
```
If NO search needed:
  Same as current:     ~2.3-2.8s  (zero overhead, heuristic is <1ms)

If search needed AND heuristic caught it:
  Search runs in parallel with screenshot + context assembly
  Search completes:    ~500-800ms (hidden behind context prep)
  Results injected into Claude context
  Claude first token:  ~1500-2000ms (same as normal — results already there)
                       ─────────────
  Total:               ~2.5-3.2s   (barely slower than no-search!)

If search needed BUT heuristic missed it:
  Falls back to Pattern A:  ~3.6-4.9s
```

**The hybrid approach makes "obvious" search queries nearly as fast as non-search queries.** The heuristic doesn't need to be perfect — it just needs to catch the easy cases. Claude handles the rest.

---

## Cost Analysis

Assuming ~50 queries/day, ~20% trigger web search:

| Component | Per Query | Monthly (10 searches/day) |
|---|---|---|
| Brave Search | ~$0.005 | ~$1.50 |
| Jina Reader (when needed) | Free | $0 |
| GitHub API | Free | $0 |
| Extra Claude tokens (tool defs) | ~$0.0003 | ~$0.45 |
| Extra Claude tokens (search results in context) | ~$0.002 | ~$0.60 |
| **Total incremental cost** | | **~$2.55/month** |

Negligible. The Brave $5/month base plan covers this easily.

---

## Decision: Pattern A vs B vs Hybrid

| Criteria | Pattern A (Tool Use) | Pattern B (Router) | Hybrid (Recommended) |
|---|---|---|---|
| Complexity to build | Low | High | Medium |
| Latency (no search) | **Zero overhead** | +200-400ms always | **Zero overhead** |
| Latency (search needed) | +1.5-2.5s | +0.5-1s | **+0.2-0.5s** (if heuristic catches it) |
| Accuracy of search decisions | High (Claude is smart) | Medium (classifier can err) | **Highest** (heuristic + Claude fallback) |
| Maintenance burden | Low | Medium (classifier tuning) | **Low** (regex list + Claude) |
| Cost | Lowest | Medium (extra model calls) | Low |

**Recommendation: Start with Pattern A. Add the heuristic pre-fetch (making it Hybrid) once you see which queries users commonly trigger search for.**

Pattern A alone is 90% of the value with 20% of the effort. You can ship it in a day. The heuristic layer is a performance optimization you add later once you have real usage data showing which query patterns are common.

---

## Response Format Changes

When Handy uses web search, the response should cite sources so the user can dig deeper. Update the system prompt to include:

```
When you use web search results to answer, briefly mention your source naturally.
Example: "According to the React Native docs, the latest version is 0.76..."
Do NOT list URLs in voice responses — just mention the source name.
In the written chat response, you may include a clickable link.
```

This keeps voice responses clean while giving the chat thread reference-ability.

---

## Summary

1. **Start with Pattern A** — add three tools (web_search, fetch_page, github_search) to your Claude API calls. Claude decides when to search. Zero overhead when it doesn't.

2. **Use Brave Search + Jina Reader + GitHub API** — fast, affordable, privacy-aligned. All callable via simple URLSession in Swift.

3. **Later, add the heuristic pre-fetch** — a regex/keyword scanner that catches obvious "needs web" queries and fires off search in parallel. This hides search latency for the most common cases.

4. **Skip the router model** (Pattern B) — it adds complexity and a latency tax on EVERY query for marginal benefit. Claude's native tool use intelligence is good enough.

5. **New Settings field** — Brave API key in Keychain, web search features disabled without it.

6. **Cost** — ~$2-5/month incremental. Negligible.
