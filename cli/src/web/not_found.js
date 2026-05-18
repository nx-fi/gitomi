(function () {
  var root = document.querySelector("[data-not-found-life]");
  if (!root) return;

  var canvas = root.querySelector(".not-found-life-canvas");
  if (!canvas) return;

  var ctx = canvas.getContext("2d", { alpha: true });
  if (!ctx) return;

  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var dpr = Math.min(window.devicePixelRatio || 1, 2);
  var cell = 6;
  var cols = 0;
  var rows = 0;
  var current = new Uint8Array(0);
  var next = new Uint8Array(0);
  var startedAt = 0;
  var lastStep = 0;
  var raf = 0;
  var resizeTimer = 0;
  var colors = {};

  function resolvedColor(name, fallback) {
    var probe = document.createElement("span");
    probe.style.color = "var(" + name + ")";
    probe.style.position = "absolute";
    probe.style.visibility = "hidden";
    document.body.appendChild(probe);
    var value = getComputedStyle(probe).color || fallback;
    probe.remove();
    return value;
  }

  function readColors() {
    colors = {
      grid: resolvedColor("--border", "rgb(120 130 130)"),
      alive: resolvedColor("--brand", "rgb(0 156 143)"),
      born: resolvedColor("--orange", "rgb(174 133 46)")
    };
  }

  function configure() {
    readColors();

    var rect = root.getBoundingClientRect();
    var width = Math.max(320, Math.floor(rect.width));
    var height = Math.max(320, Math.floor(rect.height));

    cell = width < 640 ? 5 : 6;
    cols = Math.ceil(width / cell);
    rows = Math.ceil(height / cell);
    current = new Uint8Array(cols * rows);
    next = new Uint8Array(cols * rows);

    canvas.width = Math.floor(width * dpr);
    canvas.height = Math.floor(height * dpr);
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    seed404();
    startedAt = performance.now() + 2000;
    lastStep = 0;
    draw();
  }

  function seed404() {
    var mask = document.createElement("canvas");
    mask.width = cols;
    mask.height = rows;
    var maskCtx = mask.getContext("2d");
    if (!maskCtx) return;

    var fontSize = Math.floor(Math.min(cols * 0.42, rows * 0.62));
    maskCtx.clearRect(0, 0, cols, rows);
    maskCtx.fillStyle = "#fff";
    maskCtx.font = "900 " + fontSize + "px Inter, Avenir Next, Arial, sans-serif";
    maskCtx.textAlign = "center";
    maskCtx.textBaseline = "middle";
    maskCtx.fillText("404", cols / 2, rows * 0.46);

    var data = maskCtx.getImageData(0, 0, cols, rows).data;
    for (var y = 0; y < rows; y += 1) {
      for (var x = 0; x < cols; x += 1) {
        var alpha = data[(y * cols + x) * 4 + 3];
        if (alpha > 64) current[y * cols + x] = 1;
      }
    }
  }

  function step() {
    next.fill(0);
    for (var y = 1; y < rows - 1; y += 1) {
      for (var x = 1; x < cols - 1; x += 1) {
        var i = y * cols + x;
        var n =
          current[i - cols - 1] + current[i - cols] + current[i - cols + 1] +
          current[i - 1] + current[i + 1] +
          current[i + cols - 1] + current[i + cols] + current[i + cols + 1];
        next[i] = n === 3 || (current[i] && n === 2) ? 1 : 0;
      }
    }
    var swap = current;
    current = next;
    next = swap;
  }

  function drawGrid(width, height) {
    ctx.save();
    ctx.globalAlpha = 0.22;
    ctx.strokeStyle = colors.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (var x = 0; x <= cols; x += 1) {
      var px = x * cell + 0.5;
      ctx.moveTo(px, 0);
      ctx.lineTo(px, height);
    }
    for (var y = 0; y <= rows; y += 1) {
      var py = y * cell + 0.5;
      ctx.moveTo(0, py);
      ctx.lineTo(width, py);
    }
    ctx.stroke();
    ctx.restore();
  }

  function drawCells(now) {
    var waiting = now < startedAt;
    ctx.fillStyle = waiting ? colors.alive : colors.born;
    for (var y = 0; y < rows; y += 1) {
      for (var x = 0; x < cols; x += 1) {
        if (!current[y * cols + x]) continue;
        ctx.fillRect(x * cell + 1, y * cell + 1, Math.max(1, cell - 1), Math.max(1, cell - 1));
      }
    }
  }

  function draw() {
    var width = canvas.width / dpr;
    var height = canvas.height / dpr;
    var now = performance.now();

    ctx.clearRect(0, 0, width, height);
    drawGrid(width, height);
    drawCells(now);

    if (!reduceMotion && now >= startedAt && now - lastStep > 90) {
      step();
      lastStep = now;
    }

    raf = requestAnimationFrame(draw);
  }

  function scheduleResize() {
    window.clearTimeout(resizeTimer);
    resizeTimer = window.setTimeout(configure, 120);
  }

  window.addEventListener("resize", scheduleResize);
  window.addEventListener("storage", function (event) {
    if (event.key && event.key.indexOf("gitomi.theme") === 0) window.setTimeout(readColors, 80);
  });

  configure();
}());
