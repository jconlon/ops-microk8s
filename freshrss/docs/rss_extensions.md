# FreshRSS Extensions: Biggest Usability Gains for Power Users

## Overview

FreshRSS has a rich ecosystem of third-party extensions that plug into its hook system to modify everything from content fetching to UI layout. For a power user managing hundreds of feeds, publishing curated content, and running FreshRSS on Kubernetes, the extensions below deliver the most impactful usability improvements. They are grouped by the type of friction they eliminate.[1]

## Full-Text Content Fetching

### Readable / Article Full Text

Many feeds only ship truncated summaries, forcing users to click through to the original site. The **Readable** extension solves this by fetching full article content server-side via three interchangeable backends: Readability.js, Mercury Parser, or FiveFilters Full-Text RSS. An alternative, **Article Full Text** by @Niehztog, bundles the FiveFilters Readability.php library directly so no extra Docker containers are needed.[2][3][4]

This is arguably the single highest-impact extension for any power user. It turns FreshRSS from a headline scanner into a true reading environment, eliminating the constant context-switching of opening browser tabs. Setup typically involves adding one or two sidecar containers (readability-js-server, mercury-parser-api, or fivefilters) to your existing Compose/K8s manifests and pointing the extension at their internal service URLs.[5][6][3]

### FlareSolverr

An increasing number of sites hide behind Cloudflare bot challenges, causing FreshRSS feed fetches to fail silently. The **FlareSolverr extension** proxies feed requests through a headless browser that solves Cloudflare challenges automatically. It runs as a separate container alongside FreshRSS. For power users tracking tech blogs and Substack newsletters, this extension rescues otherwise unreachable feeds.[7][8][9]

## Feed Refresh Intelligence

### AutoTTL

Power users subscribe to feeds that update at wildly different cadences — some post hourly, others weekly. **AutoTTL** dynamically adjusts each feed's refresh interval based on its historical posting frequency. Feeds with frequent new entries are polled more often; dormant feeds are checked less, reducing unnecessary load. The configurable max TTL sets an upper bound (e.g., default 1 h, max 24 h), keeping your instance efficient without manual per-feed tuning.[10]

## Read-Later and Publishing Integration

### Wallabag Button

For users integrating FreshRSS with Wallabag, the **Wallabag Button** extension adds a one-click button that sends articles via the Wallabag v2 API server-side, without opening a new browser tab. FreshRSS has a built-in Wallabag "share" link, but that link opens a new tab and breaks the reading flow. The extension's API-based approach keeps the workflow seamless — triage feeds, tap the button, and keep moving.[11]

### Pocket Button / Star To Pocket

Similar to the Wallabag Button, the **Pocket Button** adds a one-click send-to-Pocket action. **Star To Pocket** goes further: it automatically sends any article you star to Pocket, which means it works from any FreshRSS client app (NewsFlash, RSS Guard, etc.) — not just the web UI.[4]

### Share To Linkwarden / Readeck Button

For self-hosted bookmark managers, **Share To Linkwarden** and **Readeck Button** provide analogous one-click server-side saving.[4]

## AI-Powered Summarization

### ArticleSummary

The **ArticleSummary** extension adds a "Summarize" button to every article. It converts the HTML to Markdown and sends it to any OpenAI API-compatible endpoint (OpenAI, Ollama, LM Studio, etc.) with a configurable system prompt. For power users triaging high volumes of long-form content, this lets you read a two-paragraph digest before deciding whether to invest time in the full article. It supports custom base URLs, model names, and prompts — so it works with locally hosted LLMs on the same infrastructure.[12]

### Kagi Summarizer

An alternative for Kagi subscribers, the **Kagi Summarizer** extension uses the Kagi Universal Summarizer API to generate per-article summaries. It requires a Kagi API key rather than managing your own LLM endpoint.[4]

## UI and Reading Experience

### Custom CSS (Core Extension)

**Custom CSS** ships with FreshRSS core but must be enabled manually. It lets users inject arbitrary CSS to tighten padding, resize fonts, shrink headers, or restyle the entire UI. Power users commonly use it to reclaim vertical space on non-4K monitors, adjust dark-mode contrast, and compact article list rows.[13][14][15][4]

### ThemeModeSynchronizer

Automatically syncs FreshRSS's light/dark theme to the system preference, eliminating the need to toggle manually when switching between day and night usage.[4]

### Keep Folder State / Fixed Nav Menu / Mobile Scroll Menu / Touch Control

This suite by @oYoX addresses navigation pain points:[4]

- **Keep Folder State** remembers which feed folders are expanded, restoring them on reload.
- **Fixed Nav Menu** pins the sidebar when scrolling long article lists.
- **Mobile Scroll Menu** auto-hides the header bar on scroll, reclaiming mobile screen space.
- **Touch Control** adds swipe gestures for mobile browsing.

These are small individually but collectively make FreshRSS feel like a polished native app rather than a web page.

### Youlag

For users who follow YouTube channels via RSS, **Youlag** replaces the default FreshRSS article view with a YouTube-style video grid layout with inline playback, picture-in-picture, fullscreen mode, and mobile-friendly menus. It optionally routes playback through a self-hosted Invidious instance for privacy. This is a major usability gain if video feeds represent a significant portion of subscriptions.[16][17]

### Reading Time

Adds an estimated reading time next to each article title. A quick signal that helps power users prioritize articles during triage.[4]

## Image and Content Optimization

### Image Cache

The **Image Cache** extension rewrites image URLs in articles to point to a caching layer — either a self-hosted server or a Cloudflare Worker. Benefits include faster loading (especially on mobile), reduced bandwidth to origin servers, and continued access to images even if the original site removes them. Setup involves deploying a small cache service and configuring the extension with the cache URL and an access token.[18][19]

## Feed Generation and Filtering

### YouTube Channel 2 RSSFeed / Twitch Channel 2 RSSFeed / RedditSub

These extensions convert platform URLs into usable RSS feeds directly inside FreshRSS, so users do not need to manually construct feed URLs or rely on external services like RSS-Bridge.[4]

### FilterTitle / Black List / RemoveEmojis / Word Highlighter

Filtering extensions let power users suppress noise:

- **FilterTitle** drops entries matching keyword patterns in the title.[4]
- **Black List** blocks entire feeds for specific users (useful in multi-user deployments).[4]
- **RemoveEmojis** strips emoji clutter from titles.[4]
- **Word Highlighter** visually flags user-defined keywords using mark.js.[4]

## Recommendations for Your Stack

Given a Kubernetes-hosted FreshRSS instance backed by PostgreSQL, with NewsFlash as a frontend and a publishing pipeline that curates tagged articles into Hugo blog posts, the extensions that deliver the most immediate value are:

| Extension                        | Why It Matters for Your Workflow                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------------- |
| **Readable / Article Full Text** | Read full articles in FreshRSS/NewsFlash without tab-switching; improves triage speed[3][4] |
| **AutoTTL**                      | Automatically tunes refresh rates across many feeds; reduces unnecessary K8s pod load[10]   |
| **Wallabag Button**              | Seamless server-side send to Wallabag without leaving the reading flow[11]                  |
| **ArticleSummary**               | Quick LLM-generated digests for high-volume triage; works with self-hosted models[12]       |
| **FlareSolverr**                 | Recovers Cloudflare-blocked feeds silently[8]                                               |
| **Custom CSS**                   | Tighten the web UI for efficient keyboard-driven triage[13][14]                             |
| **Image Cache**                  | Speeds up article rendering and preserves images long-term[18]                              |

These seven extensions address the primary friction points in a power-user RSS workflow: incomplete content, noisy feed lists, slow rendering, broken feeds, and interrupted reading flow.
