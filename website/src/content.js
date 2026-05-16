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
    code: "gt init --principal alice --device laptop\ngt issue open --title \"Move workflow into Git\"\ngt issue list"
  },
  {
    title: "Browse",
    body: "Start the loopback web UI for code, issues, projects, events, workflows, and refs.",
    code: "gt web"
  }
];

const proofItems = [
  "Issues",
  "Pull requests",
  "Comments",
  "Milestones",
  "Project Kanban",
  "Workflow runs",
  "Agent activity"
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
        <code>localhost:3821/projects/portable-v1</code>
      </div>
      <div class="app-sim">
        <aside class="sim-sidebar">
          <strong>Gitomi</strong>
          <span class="is-active"><span class="button-icon icon-projects" aria-hidden="true"></span> Board</span>
          <span><span class="button-icon icon-issues" aria-hidden="true"></span> Issues</span>
          <span><span class="button-icon icon-pull-request" aria-hidden="true"></span> PRs</span>
          <span><span class="button-icon icon-workflow" aria-hidden="true"></span> Runs</span>
          <span><span class="button-icon icon-branch" aria-hidden="true"></span> Refs</span>
        </aside>
        <section class="sim-board" aria-label="Simulated Gitomi project board">
          <div class="sim-toolbar">
            <div>
              <p>Project</p>
              <strong>Own the workflow</strong>
            </div>
            <span class="sim-button">Sync refs</span>
          </div>
          <div class="kanban-grid">
            <div class="kanban-lane">
              <h3>Local queue</h3>
              <article>
                <span class="issue-id">#128</span>
                <strong>Agent trace belongs in repo history</strong>
                <small>signed by alice/laptop</small>
              </article>
              <article>
                <span class="issue-id green">#129</span>
                <strong>Offline PR review from train Wi-Fi</strong>
                <small>3 comments pending sync</small>
              </article>
            </div>
            <div class="kanban-lane is-hot">
              <h3>Review</h3>
              <article class="is-selected">
                <span class="issue-id coral">PR-44</span>
                <strong>Replace hosted issue sync</strong>
                <small>checks passed locally</small>
              </article>
              <article>
                <span class="issue-id amber">RUN</span>
                <strong>workflow: release-notes</strong>
                <small>artifact stored with event</small>
              </article>
            </div>
            <div class="kanban-lane">
              <h3>Accepted</h3>
              <article>
                <span class="issue-id cyan">ACL</span>
                <strong>RBAC reducer verified</strong>
                <small>projection rebuilt</small>
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
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Gitomi keeps your entire development workflow - issues, PRs, projects, workflows, and agent activity - inside your Git repository.">
  <script>
    (function () {
      try {
        var stored = localStorage.getItem("gitomi.theme");
        document.documentElement.dataset.theme = stored === "light" || stored === "dark" ? stored : "dark";
      } catch (_) {
        document.documentElement.dataset.theme = "dark";
      }
    }());
  </script>
  <title>Gitomi - Own your project, not just your code</title>
  <link rel="icon" href="./assets/logo.svg" type="image/svg+xml">
  <link rel="stylesheet" href="./assets/webui.css">
  <link rel="stylesheet" href="./assets/site.css">
</head>
<body class="site-shell">
  <div class="ambient-grid" aria-hidden="true"></div>
  <div class="corner-actions" aria-label="Site actions">
    <button class="theme-toggle theme-float" type="button" data-theme-toggle aria-pressed="true" aria-label="Toggle dark mode" title="Toggle dark mode">
      <span class="theme-toggle-track" aria-hidden="true"><span class="theme-toggle-thumb"></span></span>
      <span class="theme-toggle-label" data-theme-label>Dark</span>
    </button>
    <a class="github-link" href="https://github.com/nx-fi/gitomi" target="_blank" rel="noreferrer" aria-label="GitHub repository"></a>
  </div>

  <main id="top" class="site-main">
    <svg class="flow-line" viewBox="0 0 1440 4300" preserveAspectRatio="none" aria-hidden="true">
      <defs>
        <linearGradient id="flow-line-gradient" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#70ffa6" stop-opacity="0"></stop>
          <stop offset="0.12" stop-color="#70ffa6" stop-opacity="0.44"></stop>
          <stop offset="0.5" stop-color="#64d7ff" stop-opacity="0.34"></stop>
          <stop offset="0.78" stop-color="#ffd166" stop-opacity="0.36"></stop>
          <stop offset="1" stop-color="#70ffa6" stop-opacity="0"></stop>
        </linearGradient>
      </defs>
      <path d="M 720 650 C 620 770 530 880 505 1060 C 475 1200 500 1360 515 1525 C 535 1715 520 1885 505 2025 C 490 2225 650 2365 840 2495 C 975 2595 930 2820 835 3045 C 755 3235 805 3395 895 3555 C 975 3705 820 3900 610 4110"></path>
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
        <p class="hero-lede">Gitomi keeps issues, pull requests, Kanban boards, workflows, and agent activity inside your Git repository - so you can work offline, sync with any Git remote, or self-host without losing your collaboration history.</p>
        <div class="hero-install command-code">
          <pre><code>curl gitomi.com/install.sh</code></pre>
          <button class="command-copy install-copy" type="button" data-copy-command title="Copy install command" aria-label="Copy install command">
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
          <pre><code><span class="prompt">$</span> <span data-typewriter data-words="gt issue open --title own-the-workflow|git fetch origin refs/gitomi/*|gt web --offline-ready">gt issue open --title own-the-workflow</span><span class="typing-caret"></span>
<span class="ok">accepted</span> event 9f2a1c4 projected locally
<span class="muted">sync</span> ordinary git transport ready</code></pre>
        </div>
      </div>
    </section>

    <section id="how" class="proof-section">
      <div class="section-copy">
        <p class="eyebrow">Repository-owned collaboration</p>
        <h2>All project data lives in Git.</h2>
        <p>Issues, pull requests, comments, milestones, project Kanban, workflow runs, and agent activity are stored as Git-backed project history. Your repo becomes the source of truth for both code and collaboration.</p>
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
              <div class="is-live"><span class="tree-glyph">refs/gitomi</span><strong>project history</strong><small>signed commits</small></div>
              <div><span class="tree-glyph sub">issues</span><strong>#128, #129, #131</strong><small>events</small></div>
              <div><span class="tree-glyph sub">pulls</span><strong>PR-44, PR-45</strong><small>reviews</small></div>
              <div><span class="tree-glyph sub">runs</span><strong>workflows + agents</strong><small>outputs</small></div>
            </div>
            <div class="event-stack">
              <article>
                <span class="event-kind">issue.opened</span>
                <strong>Move workflow into Git</strong>
                <small>alice/laptop signed 9f2a1c4</small>
              </article>
              <article>
                <span class="event-kind green">project.card.moved</span>
                <strong>Kanban state projected locally</strong>
                <small>refs fetched, index rebuilt</small>
              </article>
              <article>
                <span class="event-kind violet">agent.run.finished</span>
                <strong>Trace and artifact attached</strong>
                <small>durable result in repo history</small>
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
          <pre><code><span class="prompt">$</span> git fetch origin 'refs/gitomi/*:refs/gitomi/staging/*'
<span class="ok">remote</span> 42 project events received
<span class="prompt">$</span> gt sync --admit
<span class="ok">accepted</span> signatures, RBAC, chains
<span class="muted">projection</span> issues + PRs + boards rebuilt</code></pre>
          <div class="sync-feed">
            <span><b>refs/gitomi/inbox/alice</b><em>fast-forward</em></span>
            <span><b>refs/gitomi/inbox/agent-7</b><em>signed</em></span>
            <span><b>refs/gitomi/projects/portable-v1</b><em>projected</em></span>
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
        <p>Open issues, review pull requests, move cards, inspect workflow results, and continue working from your local clone. Reconnect when you are ready. Gitomi syncs project state through Git.</p>
      </div>
      <div class="offline-lab" aria-hidden="true">
        <article class="device-panel">
          <div class="device-head">
            <span></span>
            <strong>offline laptop</strong>
            <em>3 events queued</em>
          </div>
          <ul>
            <li><b>#131</b><span>Open issue</span><small>local</small></li>
            <li><b>PR-45</b><span>Review changes</span><small>local</small></li>
            <li><b>RUN</b><span>Inspect workflow result</span><small>local</small></li>
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
        <p class="eyebrow">Agent-native project record</p>
        <h2>Built for agents, not just humans.</h2>
        <p>Agent work should be reviewable, traceable, and part of the project record. Gitomi gives agents a native workflow: tasks, permissions, traces, outputs, and durable results tied to your repository.</p>
      </div>
      <div class="agent-console" aria-hidden="true">
        <div class="console-title">
          <span class="button-icon icon-workflow"></span>
          <strong>agent-run/issue-128</strong>
          <em>signed output</em>
        </div>
        <ol>
          <li><span>context</span><code>refs/heads/main + issue #128</code></li>
          <li><span>permission</span><code>write inbox only</code></li>
          <li><span>trace</span><code>tests, diff, review notes</code></li>
          <li><span>result</span><code>durable event commit</code></li>
        </ol>
      </div>
    </section>

    <section class="workflow-section">
      <div class="section-copy">
        <p class="eyebrow">Familiar model, different ownership</p>
        <h2>Replace the platform. Keep the workflow.</h2>
        <p>Use the familiar model: issues, pull requests, comments, labels, milestones, boards, workflows, and a local web UI. The difference is that your team owns the data, the workflow, and the history.</p>
      </div>
      <div class="workflow-grid">
        <article>
          <span class="button-icon icon-issues" aria-hidden="true"></span>
          <strong>Issues and comments</strong>
          <p>Portable project discussion with signed history.</p>
        </article>
        <article>
          <span class="button-icon icon-pull-request" aria-hidden="true"></span>
          <strong>Pull request reviews</strong>
          <p>Review state travels with the repository.</p>
        </article>
        <article>
          <span class="button-icon icon-projects" aria-hidden="true"></span>
          <strong>Kanban and milestones</strong>
          <p>Planning state is rebuilt from Git events.</p>
        </article>
        <article>
          <span class="button-icon icon-workflow" aria-hidden="true"></span>
          <strong>Workflows and agents</strong>
          <p>Runs, traces, and outputs join project history.</p>
        </article>
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
          <p>The repository includes the product, ref layout, and CLI references behind the implementation.</p>
        </div>
        <div class="docs-links" aria-label="Documentation links">
          <a href="./docs/README.md"><span class="button-icon icon-book" aria-hidden="true"></span> README</a>
          <a href="./docs/CLI.md"><span class="button-icon icon-code" aria-hidden="true"></span> CLI reference</a>
          <a href="./docs/01_PRODUCT.md"><span class="button-icon icon-file-code" aria-hidden="true"></span> Product spec</a>
          <a href="./docs/02_REFS.md"><span class="button-icon icon-branch" aria-hidden="true"></span> Ref spec</a>
        </div>
      </div>
    </section>
  </main>

  <footer class="site-footer">
    <img src="./assets/logo.svg" alt="" width="47" height="32">
    <span>Gitomi keeps your entire development workflow inside your Git repository.</span>
  </footer>

  <script src="./assets/theme.js"></script>
  <script src="./assets/site.js"></script>
</body>
</html>`;
}
