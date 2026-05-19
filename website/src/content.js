/**
 * @typedef {object} CommandBlock
 * @property {string} title
 * @property {string} body
 * @property {string} code
 */

/** @type {CommandBlock[]} */
const commandBlocks = [
  {
    title: "Build",
    body: "Compile the Zig CLI from the repository checkout.",
    code: "cd cli\nzig build\n./zig-out/bin/gt --help"
  },
  {
    title: "Initialize",
    body: "Attach Gitomi to an existing Git repository with a signed local device.",
    code: "gt init --principal alice --device laptop\ngt issue open --title \"Write the release notes\" --body \"Collect highlights for v1.\"\ngt issue list"
  },
  {
    title: "Browse",
    body: "Start the loopback web UI for code, issues, pull requests, projects, pipelines, events, and refs.",
    code: "gt web"
  }
];

const proofItems = [
  "Issues",
  "Pull requests",
  "Comments",
  "Milestones",
  "Project boards",
  "Pipeline runs",
  "Notifications"
];

/**
 * Escape HTML text content.
 * @param {string} value
 * @returns {string}
 */
function html(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/**
 * Render a command block with copy affordances.
 * @param {CommandBlock} block
 * @returns {string}
 */
function renderCommandBlock(block) {
  return `
    <article class="command-card">
      <div>
        <p class="eyebrow">${html(block.title)}</p>
        <p>${html(block.body)}</p>
      </div>
      <div class="command-code">
        <button class="command-copy" type="button" data-copy-command title="Copy ${html(block.title)} command" aria-label="Copy ${html(block.title)} command">
          <span class="button-icon icon-copy" aria-hidden="true"></span>
        </button>
        <pre><code>${html(block.code)}</code></pre>
      </div>
    </article>
  `;
}

/**
 * Render the simulated project board in the hero.
 * @returns {string}
 */
function renderHeroBoard() {
  return `
    <div class="browser-shot">
      <div class="shot-chrome">
        <span class="window-dot red"></span>
        <span class="window-dot amber"></span>
        <span class="window-dot green"></span>
        <code>127.0.0.1:12655/projects?project=Portable%20v1&amp;view=board</code>
      </div>
      <div class="app-sim">
        <aside class="sim-sidebar">
          <strong>Gitomi</strong>
          <span><span class="button-icon icon-code" aria-hidden="true"></span> Code</span>
          <span><span class="button-icon icon-issues" aria-hidden="true"></span> Issues</span>
          <span><span class="button-icon icon-pull-request" aria-hidden="true"></span> Pull Requests</span>
          <span><span class="button-icon icon-workflow" aria-hidden="true"></span> Pipelines</span>
          <span class="is-active"><span class="button-icon icon-projects" aria-hidden="true"></span> Projects</span>
        </aside>
        <section class="sim-board" aria-label="Simulated Gitomi project board">
          <div class="sim-toolbar">
            <div>
              <p>Project</p>
              <strong>Portable v1</strong>
            </div>
            <span class="sim-button">Sync refs</span>
          </div>
          <div class="kanban-grid">
            <div class="kanban-lane">
              <h3>Todo</h3>
              <article>
                <span class="issue-id">#9f2a1c4</span>
                <strong>Document the signed event format</strong>
                <small>issue.opened by alice/laptop</small>
              </article>
              <article>
                <span class="issue-id green">#37b40e1</span>
                <strong>Import GitHub labels into local index</strong>
                <small>labels and milestone projected</small>
              </article>
            </div>
            <div class="kanban-lane is-hot">
              <h3>Review</h3>
              <article class="is-selected">
                <span class="issue-id coral">#a81f2d0</span>
                <strong>Render pull request file comments</strong>
                <small>review note stored as comment.added</small>
              </article>
              <article>
                <span class="issue-id amber">RUN</span>
                <strong>pipeline: release.yml</strong>
                <small>action.run_completed accepted</small>
              </article>
            </div>
            <div class="kanban-lane">
              <h3>Done</h3>
              <article>
                <span class="issue-id cyan">ACL</span>
                <strong>Team role grant projects correctly</strong>
                <small>index rebuilt from inbox refs</small>
              </article>
            </div>
          </div>
        </section>
      </div>
      <div class="click-cursor" aria-hidden="true"><span></span></div>
    </div>
  `;
}

/**
 * Render the static public-facing site.
 * @returns {string}
 */
export function renderSite() {
  return `<!doctype html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Gitomi keeps issues, pull requests, projects, pipeline run records, notifications, and access-control events inside your Git repository.">
  <meta name="theme-color" content="#009c8f">
  <title>Gitomi - Own your project, not just your code</title>
  <link rel="icon" href="./assets/logo.svg" type="image/svg+xml">
  <link rel="stylesheet" href="./assets/webui.css">
  <link rel="stylesheet" href="./assets/site.css">
</head>
<body class="site-shell">
  <a class="skip-link" href="#top">Skip to content</a>
  <div class="ambient-grid" aria-hidden="true"></div>
  <div class="corner-actions" aria-label="Site actions">
    <a class="github-link" href="https://github.com/nx-fi/gitomi" target="_blank" rel="noreferrer" aria-label="GitHub repository"></a>
  </div>

  <main id="top" class="site-main" tabindex="-1">
    <svg class="flow-line" viewBox="0 0 1440 4300" preserveAspectRatio="none" aria-hidden="true">
      <defs>
        <linearGradient id="flow-line-green" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#009c8f" stop-opacity="0"></stop>
          <stop offset="0.18" stop-color="#009c8f" stop-opacity="0.46"></stop>
          <stop offset="0.56" stop-color="#73b7fc" stop-opacity="0.34"></stop>
          <stop offset="0.84" stop-color="#009c8f" stop-opacity="0.36"></stop>
          <stop offset="1" stop-color="#009c8f" stop-opacity="0"></stop>
        </linearGradient>
        <linearGradient id="flow-line-cyan" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#73b7fc" stop-opacity="0"></stop>
          <stop offset="0.2" stop-color="#73b7fc" stop-opacity="0.42"></stop>
          <stop offset="0.58" stop-color="#b3566f" stop-opacity="0.32"></stop>
          <stop offset="0.86" stop-color="#009c8f" stop-opacity="0.3"></stop>
          <stop offset="1" stop-color="#73b7fc" stop-opacity="0"></stop>
        </linearGradient>
        <linearGradient id="flow-line-amber" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#ffd481" stop-opacity="0"></stop>
          <stop offset="0.18" stop-color="#ffd481" stop-opacity="0.38"></stop>
          <stop offset="0.55" stop-color="#009c8f" stop-opacity="0.28"></stop>
          <stop offset="0.84" stop-color="#73b7fc" stop-opacity="0.24"></stop>
          <stop offset="1" stop-color="#ffd481" stop-opacity="0"></stop>
        </linearGradient>
        <linearGradient id="flow-line-violet" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#b3566f" stop-opacity="0"></stop>
          <stop offset="0.2" stop-color="#b3566f" stop-opacity="0.38"></stop>
          <stop offset="0.58" stop-color="#73b7fc" stop-opacity="0.3"></stop>
          <stop offset="0.86" stop-color="#cd6e86" stop-opacity="0.22"></stop>
          <stop offset="1" stop-color="#b3566f" stop-opacity="0"></stop>
        </linearGradient>
      </defs>
      <g class="flow-stream">
        <path class="flow-path flow-green" d="M 720 650 C 598 735 390 850 318 1065 C 276 1190 315 1270 392 1372 C 530 1552 560 1742 392 1988 C 332 2074 318 2138 372 2205 C 462 2320 690 2415 812 2518 C 1008 2680 960 2910 868 3128 C 805 3280 782 3428 872 3545 C 990 3695 805 3905 610 4110"></path>
        <path class="flow-path flow-cyan" d="M 690 660 C 540 760 350 890 304 1098 C 278 1212 320 1288 402 1390 C 548 1570 548 1755 382 1976 C 324 2050 322 2110 386 2188 C 492 2310 650 2405 792 2530 C 940 2660 838 2880 852 3138 C 860 3308 752 3432 842 3580 C 922 3740 760 3925 555 4100"></path>
        <path class="flow-path flow-amber" d="M 750 650 C 640 782 450 930 348 1150 C 300 1258 318 1348 268 1508 C 220 1665 278 1815 390 1988 C 442 2072 424 2154 350 2238 C 258 2344 672 2390 862 2488 C 1010 2562 1032 2882 888 3095 C 770 3270 875 3380 945 3520 C 1035 3695 900 3908 690 4130"></path>
        <path class="flow-path flow-violet" d="M 655 705 C 472 815 250 968 285 1148 C 318 1295 555 1362 608 1532 C 668 1722 486 1832 312 1998 C 232 2074 250 2162 402 2248 C 512 2310 608 2400 835 2538 C 1005 2640 994 2985 852 3188 C 738 3340 735 3420 820 3595 C 895 3750 720 3920 525 4090"></path>
        <path class="flow-path flow-green" d="M 785 675 C 690 812 520 920 395 1125 C 326 1240 450 1395 690 1590 C 828 1700 628 1860 418 2008 C 328 2072 278 2162 334 2242 C 420 2360 760 2340 900 2495 C 1018 2625 1102 2920 895 3148 C 765 3292 902 3405 980 3565 C 1060 3725 912 3920 735 4150"></path>
        <path class="flow-path flow-cyan" d="M 625 760 C 455 915 345 1020 328 1195 C 312 1355 198 1465 300 1652 C 382 1800 592 1900 430 2012 C 312 2094 250 2176 412 2265 C 520 2325 800 2415 1028 2670 C 1125 2780 1085 2960 878 3160 C 710 3320 905 3505 982 3650 C 1050 3785 870 3978 720 4140"></path>
        <path class="flow-path flow-amber" d="M 735 720 C 590 835 405 945 335 1108 C 275 1250 395 1410 468 1590 C 548 1788 460 1915 340 2018 C 262 2084 258 2175 382 2248 C 528 2334 650 2385 850 2500 C 980 2578 748 2862 865 3155 C 942 3348 822 3408 910 3570 C 998 3735 835 3928 650 4120"></path>
        <path class="flow-path flow-violet" d="M 595 810 C 430 950 315 1055 340 1205 C 368 1378 592 1440 452 1625 C 350 1760 260 1900 326 2028 C 365 2102 490 2164 650 2268 C 815 2375 912 2415 980 2618 C 1065 2875 1110 2988 850 3182 C 712 3285 842 3480 920 3648 C 990 3802 805 3985 585 4170"></path>
        <path class="flow-path flow-green" d="M 805 725 C 660 870 485 965 362 1138 C 292 1235 590 1388 735 1580 C 858 1744 610 1886 400 2035 C 312 2098 328 2184 488 2268 C 702 2380 780 2358 930 2505 C 1100 2672 1085 2965 870 3170 C 748 3288 882 3370 1018 3580 C 1110 3720 930 3930 760 4160"></path>
      </g>
    </svg>
    <section class="hero-section" aria-labelledby="hero-title">
      <div class="hero-copy">
        <div class="brand-slot" data-brand-slot>
          <a class="hero-brand" href="#top" aria-label="Gitomi home" data-floating-brand>
            <img src="./assets/logo.svg" alt="" width="54" height="37">
            <span>Gitomi</span>
          </a>
        </div>
        <p class="pain-line">Open source, free forever.</p>
        <h1 id="hero-title">
          <span class="hero-title-line"><span class="hero-title-prefix">Own your </span><span class="hero-word-frame"><span class="hero-rotator" data-typewriter data-words="project|tasks|workflows|collaboration">project</span><span class="hero-title-caret" aria-hidden="true"></span><span class="hero-comma">,</span></span></span>
          <span class="hero-title-line">not just your code.</span>
        </h1>
        <p class="hero-lede">Gitomi keeps issues, pull requests, project boards, milestones, comments, pipeline run records, notifications, and access-control events inside your Git repository - so you can work offline, sync with any Git remote, or self-host without losing your collaboration history.</p>
        <div class="hero-install command-code">
          <pre><code>cd cli && zig build</code></pre>
          <button class="command-copy install-copy" type="button" data-copy-command title="Copy build command" aria-label="Copy build command">
            <span class="button-icon icon-copy" aria-hidden="true"></span>
          </button>
        </div>
        <div class="hero-actions">
          <a class="button primary" href="#start">Start locally</a>
          <a class="button secondary" href="#how">See how it works</a>
        </div>
        <p class="trust-line">No central database. No required server. No custom transport.</p>
      </div>

      <div class="hero-stage" aria-hidden="true">
        <div class="repo-card">
          <span class="button-icon icon-branch" aria-hidden="true"></span>
          <strong>refs/gitomi/*</strong>
          <small>signed project history</small>
        </div>
        ${renderHeroBoard()}
        <div class="terminal-shot">
          <div class="terminal-head">
            <span></span>
            <strong>alice@repo</strong>
          </div>
          <pre><code data-terminal-demo data-commands="gt issue open --title &quot;Write release notes&quot;|gt sync --remote origin|gt web" data-primary-labels="wrote|synced|serving" data-primary-lines="signed issue.opened event|signed Gitomi refs through origin|local web UI on 127.0.0.1:12655" data-secondary-labels="index|projection|pages" data-secondary-lines="rebuilt from refs/gitomi/inbox/*|updated issues, PRs, projects, and runs|code, issues, projects, pipelines"><span class="prompt" aria-hidden="true">$</span> <span data-terminal-command>gt issue open --title &quot;Write release notes&quot;</span><span class="typing-caret"></span><span data-terminal-output-lines><span data-terminal-primary-output>
<span class="ok" data-terminal-primary-label>wrote</span> <span data-terminal-primary-line>signed issue.opened event</span></span><span data-terminal-secondary-output>
<span class="muted" data-terminal-secondary-label>index</span> <span data-terminal-secondary-line>rebuilt from refs/gitomi/inbox/*</span></span></span></code></pre>
        </div>
      </div>
    </section>

    <section id="how" class="proof-section">
      <div class="section-copy">
        <p class="eyebrow">Repository-owned collaboration</p>
        <h2>All project metadata lives in the same Git repo.</h2>
        <p>Issues, pull requests, comments, milestones, project boards, notifications, access-control changes, and pipeline run records are stored as Git-backed project history. Your repo becomes the source of truth for both code and collaboration.</p>
      </div>
      <div class="repo-proof" aria-label="Repository ref layout">
        <div class="repo-window">
          <div class="repo-window-head">
            <span class="window-dot red"></span>
            <span class="window-dot amber"></span>
            <span class="window-dot green"></span>
            <strong>Your repository</strong>
            <code>refs/gitomi/*</code>
          </div>
          <div class="repo-visual-grid">
            <div class="repo-tree">
              <div><span class="tree-glyph">main</span><strong>code branches</strong><small>normal Git</small></div>
              <div><span class="tree-glyph">v1.0</span><strong>tags</strong><small>normal Git</small></div>
              <div class="is-live"><span class="tree-glyph">refs/gitomi/genesis</span><strong>trust anchor</strong><small>signed manifest</small></div>
              <div><span class="tree-glyph sub">inbox/alice/laptop</span><strong>issues, pulls, projects</strong><small>event commits</small></div>
              <div><span class="tree-glyph sub">staging/origin/inbox</span><strong>fetched remote events</strong><small>validated before admit</small></div>
              <div><span class="tree-glyph sub">runs/local-runner</span><strong>pipeline diagnostics</strong><small>retention-managed</small></div>
            </div>
            <div class="event-stack">
              <article>
                <span class="event-kind">issue.opened</span>
                <strong>Write the release notes</strong>
                <small>alice/laptop signed 9f2a1c4</small>
              </article>
              <article>
                <span class="event-kind green">issue.status_set</span>
                <strong>Move issue to Review</strong>
                <small>board rebuilt from accepted events</small>
              </article>
              <article>
                <span class="event-kind violet">action.run_completed</span>
                <strong>Pipeline result recorded</strong>
                <small>diagnostics ref linked when present</small>
              </article>
            </div>
          </div>
        </div>
        <div class="proof-chips">
          ${proofItems.map((item) => `<span>${html(item)}</span>`).join("")}
        </div>
      </div>
    </section>

    <section class="sync-section">
      <div class="section-copy">
        <p class="eyebrow">Ordinary Git transport</p>
        <h2>Use any Git host, or host it yourself.</h2>
        <p>Gitomi syncs through ordinary Git. Use an existing Git service, a private remote, a mirror, or a fully local setup. If Git can fetch and push, your project workflow can move with it.</p>
      </div>
      <div class="sync-map" aria-hidden="true">
        <div class="sync-terminal">
          <div class="terminal-head">
            <span></span>
            <strong>git transport</strong>
          </div>
          <pre><code><span class="prompt" aria-hidden="true">$</span> gt github import
<span class="ok">imported</span> 42 issues, 7 pull requests, 118 comments
<span class="prompt" aria-hidden="true">$</span> gt sync
<span class="ok">synced</span> signed Gitomi refs through origin
<span class="muted">rebuilt</span> issues, PRs, projects, and pipeline status</code></pre>
          <div class="sync-feed">
            <span><b>refs/gitomi/genesis</b></span>
            <span><b>refs/gitomi/inbox/&lt;principal&gt;/&lt;device&gt;</b></span>
            <span><b>refs/gitomi/inbox/import-bot/github</b></span>
          </div>
        </div>
        <div class="remote-stack">
          <article>
            <span class="button-icon icon-code"></span>
            <strong>Local clone</strong>
            <small>create signed events</small>
          </article>
          <article>
            <span class="button-icon icon-sync"></span>
            <strong>Any Git remote</strong>
            <small>fetch / push refs</small>
          </article>
          <article>
            <span class="button-icon icon-branch"></span>
            <strong>Mirror or bundle</strong>
            <small>portable history</small>
          </article>
          <article>
            <span class="button-icon icon-projects"></span>
            <strong>Self-host</strong>
            <small>no required server</small>
          </article>
        </div>
        <div class="packet-rail">
          <span>fetch</span>
          <span>validate</span>
          <span>project</span>
          <span>push</span>
        </div>
      </div>
    </section>

    <section class="offline-section">
      <div class="section-copy">
        <p class="eyebrow">Local-first work</p>
        <h2>Work offline. Sync later.</h2>
        <p>Open issues, comment on pull requests, move project cards, inspect pipeline results already in your clone, and keep working locally. Reconnect when you are ready. Gitomi syncs project state through Git.</p>
      </div>
      <div class="offline-lab" aria-hidden="true">
        <article class="device-panel">
          <div class="device-head">
            <span></span>
            <strong>offline laptop</strong>
            <em>3 events queued</em>
          </div>
          <ul>
            <li><b>#c09b2aa</b><span>Open issue</span><small>signed</small></li>
            <li><b>#a81f2d0</b><span>Add PR comment</span><small>local</small></li>
            <li><b>RUN</b><span>Read pipeline result</span><small>cached</small></li>
          </ul>
        </article>
        <article class="device-panel is-online">
          <div class="device-head">
            <span></span>
            <strong>team catches up</strong>
            <em>accepted</em>
          </div>
          <div class="projection-bars">
            <span style="--bar:74%"></span>
            <span style="--bar:48%"></span>
            <span style="--bar:88%"></span>
            <span style="--bar:61%"></span>
          </div>
          <p>deterministic projection rebuilt from accepted refs</p>
        </article>
      </div>
    </section>

    <section class="agent-section">
      <div class="section-copy">
        <p class="eyebrow">Local CI/CD ownership</p>
        <h2>Own your CI/CD workflows locally.</h2>
        <p>Import your existing GitHub Actions workflows or define new ones, then run them on infrastructure you control. Gitomi gives you the flexibility to use your local setup and plug AI coding agents into CI/CD, while keeping workflow history and traceability in the repository.</p>
      </div>
      <div class="agent-console" aria-hidden="true">
        <div class="console-title">
          <span class="button-icon icon-workflow"></span>
          <strong>resolve-conflict.yml workflow</strong>
          <em>runs locally</em>
        </div>
        <div class="agent-workflow-demo">
          <div class="workflow-pane">
            <div class="workflow-pane-head">
              <span class="workflow-status"></span>
              <div>
                <strong>Resolve merge conflict</strong>
                <small>.github/workflows/resolve-conflict.yml</small>
              </div>
              <code>#142</code>
            </div>
            <ul class="workflow-steps">
              <li class="is-done"><b>1</b><span><strong>Checkout</strong></span></li>
              <li class="is-active"><b>2</b><span><strong>Local coding agent</strong></span></li>
              <li><b>3</b><span><strong>Publish</strong></span></li>
            </ul>
          </div>
          <div class="agent-bridge">
            <svg viewBox="0 0 48 14" aria-hidden="true" focusable="false">
              <path d="M6 7h36"></path>
              <path d="M11 2 6 7l5 5"></path>
              <path d="m37 2 5 5-5 5"></path>
            </svg>
          </div>
          <div class="agent-terminal-pane">
            <div class="terminal-head">
              <span></span>
              <strong>local coding agent</strong>
            </div>
            <div class="agent-session">
              <div class="agent-session-head">
                <span class="agent-avatar"></span>
                <div>
                  <strong>Mythos Coding Agent</strong>
                </div>
              </div>
              <div class="agent-code-block">
                <p><strong>Resolved conflict</strong> <span class="diff-add">(+3</span> <span class="diff-remove">-5)</span></p>
                <p class="agent-code-file">src/auth/session.ts <span class="diff-add">(+3</span> <span class="diff-remove">-5)</span></p>
                <div class="agent-code-row is-remove"><span>-</span><code>&lt;&lt;&lt;&lt;&lt;&lt;&lt; HEAD</code></div>
                <div class="agent-code-row is-remove"><span>-</span><code>return cachedSession ?? await refresh();</code></div>
                <div class="agent-code-row is-remove"><span>-</span><code>=======</code></div>
                <div class="agent-code-row is-add"><span>+</span><code>return await loadSession({ cache: true });</code></div>
                <div class="agent-code-row is-remove"><span>-</span><code>&gt;&gt;&gt;&gt;&gt;&gt;&gt; origin/main</code></div>
                <p><strong>Ran</strong> merge checks and unit tests</p>
              </div>
              <div class="agent-input-line"><span>&gt;</span><p>resolve merge conflict</p></div>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section class="workflow-section">
      <div class="section-copy">
        <p class="eyebrow">Familiar model, different ownership</p>
        <h2>Keep the workflow close to the repo.</h2>
        <p>Use the familiar model: issues, pull requests, comments, labels, milestones, boards, pipeline runs, notifications, access control, and a local web UI. The difference is that your team owns the data and the history.</p>
      </div>
      <div class="workflow-pr-screen" aria-hidden="true">
        <div class="pr-screen-head">
          <span class="button-icon icon-pull-request"></span>
          <div>
            <strong>Resolve auth session conflict</strong>
            <small>feature/session-cache into main</small>
          </div>
          <em>Ready to merge</em>
        </div>
        <div class="pr-status-band">
          <span class="is-resolved">Conflicts resolved</span>
          <span>3 checks passed</span>
          <span>Approved</span>
        </div>
        <div class="pr-file-preview">
          <div><b>src/auth/session.ts</b><small>conflict markers removed</small></div>
          <code><span class="diff-remove">-</span> &lt;&lt;&lt;&lt;&lt;&lt;&lt; HEAD</code>
          <code><span class="diff-add">+</span> return await loadSession({ cache: true });</code>
          <code><span class="diff-remove">-</span> &gt;&gt;&gt;&gt;&gt;&gt;&gt; origin/main</code>
        </div>
        <div class="pr-merge-row">
          <p>Branch is up to date. Merge commit can be created locally and synced through Git.</p>
          <strong>Merge pull request</strong>
        </div>
      </div>
    </section>

    <section id="start" class="start-section">
      <div class="section-copy">
        <p class="eyebrow">Start locally</p>
        <h2>Bring Gitomi into an existing repository.</h2>
        <p>Build the CLI, initialize a local identity, and open the web UI. No central database is required for the project record.</p>
      </div>
      <div class="command-grid">
        ${commandBlocks.map(renderCommandBlock).join("")}
      </div>
    </section>

    <section class="docs-section">
      <div class="docs-panel">
        <div>
          <p class="eyebrow">Reference</p>
          <h2>Inspect the model before trusting it.</h2>
          <p>The repository includes the product, ref layout, merge semantics, and CLI references behind the implementation.</p>
        </div>
        <div class="docs-links" aria-label="Documentation links">
          <a href="./docs/README.md"><span class="button-icon icon-book" aria-hidden="true"></span> README</a>
          <a href="./docs/CLI.md"><span class="button-icon icon-code" aria-hidden="true"></span> CLI reference</a>
          <a href="./docs/01_PRODUCT.md"><span class="button-icon icon-file-code" aria-hidden="true"></span> Product spec</a>
          <a href="./docs/02_REFS.md"><span class="button-icon icon-branch" aria-hidden="true"></span> Ref spec</a>
          <a href="./docs/06_PULL_REQUEST_MERGE_SEMANTICS.md"><span class="button-icon icon-pull-request" aria-hidden="true"></span> Merge semantics</a>
        </div>
      </div>
    </section>
  </main>

  <footer class="site-footer">
    <img src="./assets/logo.svg" alt="" width="47" height="32">
    <span>Gitomi keeps project collaboration records inside your Git repository.</span>
  </footer>

  <script src="./assets/site.js"></script>
</body>
</html>`;
}
