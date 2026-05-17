(function () {
  "use strict";

  const defaultConfig = {
    workerUrl: "/dictation.worker.js",
    libraryUrl: "/vendor/transformers/transformers.min.js",
    wasmRuntimePath: "/vendor/transformers/",
    wasmRuntimeModuleUrl: "/vendor/transformers/ort-wasm-simd-threaded.jsep.min.mjs",
    wasmRuntimeBinaryUrl: "/vendor/transformers/ort-wasm-simd-threaded.jsep.wasm",
    model: "onnx-community/distil-small.en",
    dtype: "q8",
    device: "auto",
    allowLocalModels: true,
    allowRemoteModels: false,
    localFilesOnly: true,
    localModelPath: "/models/",
    sampleRate: 16000,
    chunkMs: 8000,
    minChunkSeconds: 1.25,
    minFinalChunkSeconds: 0.25,
    task: "transcribe",
    language: "english",
  };

  const workerRequests = new Map();
  let worker = null;
  let workerRequestId = 0;
  let activeSession = null;

  function currentScriptQuery() {
    const script = document.currentScript;
    if (!script || !script.src) return "";
    const index = script.src.indexOf("?");
    return index === -1 ? "" : script.src.slice(index);
  }

  const assetQuery = currentScriptQuery();

  function dictationConfig() {
    return Object.assign({}, defaultConfig, window.gitomiDictationConfig || {});
  }

  function workerUrl(config) {
    const url = config.workerUrl || defaultConfig.workerUrl;
    return url.indexOf("?") === -1 ? url + assetQuery : url;
  }

  function ensureWorker(config) {
    if (!worker) {
      worker = new Worker(workerUrl(config), { type: "module" });
      worker.addEventListener("message", handleWorkerMessage);
      worker.addEventListener("error", function (event) {
        rejectAllWorkerRequests("Dictation worker failed: " + (event.message || "unknown error"));
      });
    }
    return worker;
  }

  function rejectAllWorkerRequests(message) {
    workerRequests.forEach(function (request) {
      request.reject(new Error(message));
    });
    workerRequests.clear();
    if (activeSession) activeSession.setError(message);
  }

  function handleWorkerMessage(event) {
    const data = event.data || {};
    if (data.type === "status") {
      if (activeSession) activeSession.setWorkerStatus(data);
      return;
    }

    const request = workerRequests.get(data.id);
    if (!request) return;
    workerRequests.delete(data.id);

    if (data.type === "result") {
      request.resolve(data);
    } else if (data.type === "error") {
      request.reject(new Error(data.message || "Transcription failed."));
    }
  }

  function transcribe(audio, config) {
    const id = ++workerRequestId;
    return new Promise(function (resolve, reject) {
      workerRequests.set(id, { resolve: resolve, reject: reject });
      ensureWorker(config).postMessage({
        type: "transcribe",
        id: id,
        audio: audio,
        config: config,
      }, [audio.buffer]);
    });
  }

  function supportError() {
    if (!window.Worker) return "Dictation needs Web Worker support.";
    if (!window.AudioContext && !window.webkitAudioContext) return "Dictation needs Web Audio support.";
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) return "Microphone access is unavailable.";
    return "";
  }

  function textareaForButton(button) {
    const editor = button.closest("[data-markdown-editor], [data-text-block-editor]");
    return editor ? editor.querySelector("[data-dictation-input]") : null;
  }

  function statusForButton(button) {
    const editor = button.closest("[data-markdown-editor], [data-text-block-editor]");
    return editor ? editor.querySelector("[data-dictation-status]") : null;
  }

  function setStatusText(button, text) {
    const status = statusForButton(button);
    if (!status) return;
    status.textContent = text || "";
    status.hidden = !text;
  }

  function setButtonState(button, state, text) {
    button.classList.toggle("is-recording", state === "recording");
    button.classList.toggle("is-loading", state === "loading");
    button.classList.toggle("is-error", state === "error");
    button.setAttribute("aria-pressed", state === "recording" ? "true" : "false");
    if (state === "recording") {
      button.title = "Stop dictation";
      button.setAttribute("aria-label", "Stop dictation");
    } else {
      button.title = "Start dictation";
      button.setAttribute("aria-label", "Start dictation");
    }
    setStatusText(button, text || "");
  }

  function mergeChunks(chunks, totalLength) {
    const merged = new Float32Array(totalLength);
    let offset = 0;
    chunks.forEach(function (chunk) {
      merged.set(chunk, offset);
      offset += chunk.length;
    });
    return merged;
  }

  function downsample(input, inputRate, outputRate) {
    if (inputRate === outputRate) return new Float32Array(input);
    const ratio = inputRate / outputRate;
    const outputLength = Math.max(1, Math.floor(input.length / ratio));
    const output = new Float32Array(outputLength);
    let inputOffset = 0;

    for (let outputOffset = 0; outputOffset < outputLength; outputOffset += 1) {
      const nextInputOffset = Math.min(input.length, Math.round((outputOffset + 1) * ratio));
      let sum = 0;
      let count = 0;
      for (let index = inputOffset; index < nextInputOffset; index += 1) {
        sum += input[index];
        count += 1;
      }
      output[outputOffset] = count > 0 ? sum / count : 0;
      inputOffset = nextInputOffset;
    }

    return output;
  }

  function transcriptText(value) {
    return String(value || "")
      .trim()
      .replace(/\s+/g, " ")
      .replace(/\bnew paragraph\b/gi, "\n\n")
      .replace(/\bnew line\b/gi, "\n")
      .replace(/\bcomma\b/gi, ",")
      .replace(/\bperiod\b/gi, ".")
      .replace(/\bfull stop\b/gi, ".")
      .replace(/\bquestion mark\b/gi, "?")
      .replace(/\bexclamation point\b/gi, "!")
      .replace(/\bcolon\b/gi, ":")
      .replace(/\bsemicolon\b/gi, ";")
      .replace(/[ \t]+([,.;:!?])/g, "$1")
      .replace(/[ \t]*\n[ \t]*/g, "\n")
      .trim();
  }

  function insertTranscript(textarea, rawText) {
    const text = transcriptText(rawText);
    if (!text) return;

    const start = textarea.selectionStart || textarea.value.length;
    const end = textarea.selectionEnd || start;
    const before = textarea.value.slice(0, start);
    const after = textarea.value.slice(end);
    const needsSpace = before.length > 0 &&
      !/[\s([{"']$/.test(before) &&
      !/^[,.;:!?\])}"']/.test(text) &&
      text.charAt(0) !== "\n";
    const replacement = (needsSpace ? " " : "") + text;
    const nextCursor = before.length + replacement.length;

    textarea.value = before + replacement + after;
    textarea.focus();
    textarea.setSelectionRange(nextCursor, nextCursor);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function audioContextCtor() {
    return window.AudioContext || window.webkitAudioContext;
  }

  function DictationSession(button, textarea) {
    this.button = button;
    this.textarea = textarea;
    this.config = dictationConfig();
    this.audioContext = null;
    this.source = null;
    this.processor = null;
    this.stream = null;
    this.flushTimer = 0;
    this.chunks = [];
    this.sampleCount = 0;
    this.pending = 0;
    this.stopped = false;
  }

  DictationSession.prototype.setWorkerStatus = function (data) {
    if (this.stopped && this.pending === 0) return;
    const status = data.status || "";
    const message = data.message || "";
    if (status === "loading") {
      setButtonState(this.button, "loading", message);
    } else if (status === "transcribing") {
      setButtonState(this.button, "recording", message);
    } else if (status === "ready" && !this.stopped) {
      setButtonState(this.button, "recording", "Listening");
    }
  };

  DictationSession.prototype.setError = function (message) {
    setButtonState(this.button, "error", message || "Dictation failed.");
  };

  DictationSession.prototype.capture = function (input) {
    if (this.stopped) return;
    const chunk = downsample(input, this.audioContext.sampleRate, this.config.sampleRate);
    this.chunks.push(chunk);
    this.sampleCount += chunk.length;
  };

  DictationSession.prototype.flush = function (force) {
    const minimumSeconds = force ? this.config.minFinalChunkSeconds : this.config.minChunkSeconds;
    if (this.sampleCount < Math.floor(minimumSeconds * this.config.sampleRate)) return false;
    const audio = mergeChunks(this.chunks, this.sampleCount);
    this.chunks = [];
    this.sampleCount = 0;
    this.pending += 1;
    setButtonState(this.button, this.stopped ? "loading" : "recording", "Transcribing");

    transcribe(audio, this.config).then(function (result) {
      insertTranscript(this.textarea, result.text || "");
      if (!this.stopped) setButtonState(this.button, "recording", "Listening");
    }.bind(this)).catch(function (error) {
      this.setError(error.message || "Transcription failed.");
    }.bind(this)).finally(function () {
      this.pending -= 1;
      if (this.stopped && this.pending <= 0) {
        setButtonState(this.button, "idle", "");
      }
    }.bind(this));
    return true;
  };

  DictationSession.prototype.start = async function () {
    const unsupported = supportError();
    if (unsupported) {
      this.setError(unsupported);
      return false;
    }

    setButtonState(this.button, "loading", "Requesting microphone");
    const AudioContextCtor = audioContextCtor();
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });
    this.audioContext = new AudioContextCtor();
    await this.audioContext.resume();
    this.source = this.audioContext.createMediaStreamSource(this.stream);
    this.processor = this.audioContext.createScriptProcessor(4096, 1, 1);
    this.processor.onaudioprocess = function (event) {
      this.capture(event.inputBuffer.getChannelData(0));
    }.bind(this);
    this.source.connect(this.processor);
    this.processor.connect(this.audioContext.destination);
    this.flushTimer = window.setInterval(function () {
      this.flush();
    }.bind(this), this.config.chunkMs);
    setButtonState(this.button, "recording", "Listening");
    this.textarea.focus();
    return true;
  };

  DictationSession.prototype.stop = function () {
    this.stopped = true;
    if (this.flushTimer) {
      window.clearInterval(this.flushTimer);
      this.flushTimer = 0;
    }
    if (this.processor) {
      this.processor.disconnect();
      this.processor.onaudioprocess = null;
      this.processor = null;
    }
    if (this.source) {
      this.source.disconnect();
      this.source = null;
    }
    if (this.stream) {
      this.stream.getTracks().forEach(function (track) { track.stop(); });
      this.stream = null;
    }
    if (this.audioContext) {
      this.audioContext.close().catch(function () {});
      this.audioContext = null;
    }
    this.flush(true);
    if (this.pending === 0) setButtonState(this.button, "idle", "");
    if (activeSession === this) activeSession = null;
  };

  async function toggleDictation(button) {
    const textarea = textareaForButton(button);
    if (!textarea) return;

    if (activeSession && activeSession.button === button) {
      activeSession.stop();
      return;
    }
    if (activeSession) activeSession.stop();

    const session = new DictationSession(button, textarea);
    activeSession = session;
    try {
      const started = await session.start();
      if (!started && activeSession === session) activeSession = null;
    } catch (error) {
      session.stop();
      session.setError(error.message || "Could not start dictation.");
    }
  }

  function initDictationControls(root) {
    const scope = root || document;
    scope.querySelectorAll("[data-dictation-toggle]").forEach(function (button) {
      if (button.dataset.dictationReady === "yes") return;
      button.dataset.dictationReady = "yes";
      button.setAttribute("aria-pressed", "false");
      button.addEventListener("click", function () {
        toggleDictation(button);
      });
    });
  }

  window.addEventListener("beforeunload", function () {
    if (activeSession) activeSession.stop();
  });

  document.addEventListener("gitomi:partial-refresh", function (event) {
    const detail = event.detail || {};
    initDictationControls(detail.root || document);
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      initDictationControls(document);
    });
  } else {
    initDictationControls(document);
  }
})();
