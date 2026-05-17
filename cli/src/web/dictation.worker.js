(function () {
  "use strict";

  const defaultConfig = {
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
    task: "transcribe",
    language: "english",
  };

  let transformersModule = null;
  let transformersUrl = "";
  let transcriberPromise = null;
  let transcriberKey = "";
  let messageQueue = Promise.resolve();
  let webgpuDisabledReason = "";

  function mergedConfig(config) {
    return Object.assign({}, defaultConfig, config || {});
  }

  function errorMessage(error) {
    if (!error) return "Unknown error";
    if (typeof error.message === "string" && error.message) return error.message;
    return String(error);
  }

  function postStatus(status, message, detail) {
    self.postMessage({
      type: "status",
      status: status,
      message: message,
      detail: detail || null,
    });
  }

  function trailingSlash(value) {
    return value && value.charAt(value.length - 1) === "/" ? value : value + "/";
  }

  async function importTransformers(config) {
    const libraryUrl = config.libraryUrl || defaultConfig.libraryUrl;
    if (!transformersModule || transformersUrl !== libraryUrl) {
      postStatus("loading", "Loading Transformers.js");
      transformersModule = await import(libraryUrl);
      transformersUrl = libraryUrl;
    }
    return transformersModule;
  }

  function configureEnvironment(env, config) {
    if (!env) return;
    if (typeof config.allowRemoteModels === "boolean") {
      env.allowRemoteModels = config.allowRemoteModels;
    }
    if (typeof config.allowLocalModels === "boolean") {
      env.allowLocalModels = config.allowLocalModels;
    }
    if (typeof config.localModelPath === "string" && config.localModelPath) {
      env.localModelPath = config.localModelPath;
    }
    if (typeof config.remoteHost === "string" && config.remoteHost) {
      env.remoteHost = config.remoteHost;
    }
    if (env.backends && env.backends.onnx && env.backends.onnx.wasm) {
      const wasmRuntimePath = trailingSlash(config.wasmRuntimePath || defaultConfig.wasmRuntimePath);
      env.backends.onnx.wasm.wasmPaths = {
        mjs: config.wasmRuntimeModuleUrl || wasmRuntimePath + "ort-wasm-simd-threaded.jsep.min.mjs",
        wasm: config.wasmRuntimeBinaryUrl || wasmRuntimePath + "ort-wasm-simd-threaded.jsep.wasm",
      };
      env.backends.onnx.wasm.proxy = false;
      if (Number.isFinite(config.wasmNumThreads)) {
        env.backends.onnx.wasm.numThreads = config.wasmNumThreads;
      }
    }
  }

  function progressMessage(progress) {
    if (!progress || typeof progress !== "object") return "";
    if (progress.status === "progress" && typeof progress.progress === "number") {
      const file = progress.file ? " " + progress.file : "";
      return "Loading model" + file + " " + Math.round(progress.progress) + "%";
    }
    if (progress.status === "ready") return "Model ready";
    if (progress.status === "initiate") return "Preparing model";
    if (progress.status === "download") return "Loading model";
    return "";
  }

  function candidateDevices(config) {
    if (config.device && config.device !== "auto") return [config.device];
    if (webgpuDisabledReason) return ["wasm"];
    return self.navigator && self.navigator.gpu ? ["webgpu", "wasm"] : ["wasm"];
  }

  function pipelineOptions(device, config) {
    const options = {
      device: device,
      progress_callback: function (progress) {
        const message = progressMessage(progress);
        if (message) postStatus("loading", message, progress);
      },
    };
    if (config.dtype) options.dtype = config.dtype;
    if (typeof config.localFilesOnly === "boolean") options.local_files_only = config.localFilesOnly;
    if (config.quantized !== undefined) options.quantized = Boolean(config.quantized);
    return options;
  }

  function pipelineKey(config) {
    return JSON.stringify({
      libraryUrl: config.libraryUrl,
      model: config.model,
      device: config.device,
      dtype: config.dtype || null,
      quantized: config.quantized,
      localModelPath: config.localModelPath || "",
      wasmRuntimePath: config.wasmRuntimePath || "",
      wasmRuntimeModuleUrl: config.wasmRuntimeModuleUrl || "",
      wasmRuntimeBinaryUrl: config.wasmRuntimeBinaryUrl || "",
      localFilesOnly: config.localFilesOnly,
      allowLocalModels: config.allowLocalModels,
      allowRemoteModels: config.allowRemoteModels,
      remoteHost: config.remoteHost || "",
    });
  }

  async function loadTranscriber(config) {
    const key = pipelineKey(config);
    if (transcriberPromise && transcriberKey === key) return transcriberPromise;

    transcriberKey = key;
    transcriberPromise = (async function () {
      const mod = await importTransformers(config);
      configureEnvironment(mod.env, config);
      if (typeof mod.pipeline !== "function") {
        throw new Error("Transformers.js did not expose pipeline().");
      }

      let lastError = null;
      const devices = candidateDevices(config);
      for (let index = 0; index < devices.length; index += 1) {
        const device = devices[index];
        try {
          postStatus("loading", "Loading " + config.model + " on " + device);
          const pipe = await mod.pipeline(
            "automatic-speech-recognition",
            config.model,
            pipelineOptions(device, config),
          );
          postStatus("ready", "Dictation ready on " + device, { device: device, model: config.model });
          return { pipe: pipe, device: device };
        } catch (error) {
          lastError = error;
          if (device === "webgpu" && devices.indexOf("wasm") !== -1) {
            webgpuDisabledReason = errorMessage(error);
            postStatus("loading", "WebGPU unavailable, falling back to WASM", { message: webgpuDisabledReason });
          }
        }
      }

      throw lastError || new Error("Could not load speech recognition model.");
    })();
    transcriberPromise.catch(function () {
      if (transcriberKey === key) {
        transcriberKey = "";
        transcriberPromise = null;
      }
    });

    return transcriberPromise;
  }

  function clearTranscriber(config) {
    if (transcriberKey === pipelineKey(config)) {
      transcriberKey = "";
      transcriberPromise = null;
    }
  }

  function transcriptionOptions(config) {
    const options = {
      sampling_rate: config.sampleRate || defaultConfig.sampleRate,
    };
    if (config.language) options.language = config.language;
    if (config.task) options.task = config.task;
    if (config.chunkLengthSeconds) options.chunk_length_s = config.chunkLengthSeconds;
    if (config.strideLengthSeconds) options.stride_length_s = config.strideLengthSeconds;
    return options;
  }

  function recognizedText(result) {
    if (!result) return "";
    if (typeof result === "string") return result;
    if (Array.isArray(result)) {
      return result.map(recognizedText).filter(Boolean).join(" ");
    }
    if (typeof result.text === "string" && result.text) return result.text;
    if (Array.isArray(result.chunks)) {
      return result.chunks.map(function (chunk) {
        return chunk && typeof chunk.text === "string" ? chunk.text : "";
      }).filter(Boolean).join(" ");
    }
    return "";
  }

  async function handleTranscribe(data) {
    const id = data.id;
    const config = mergedConfig(data.config);
    try {
      let loaded = await loadTranscriber(config);
      let result = null;

      try {
        postStatus("transcribing", "Transcribing");
        result = await loaded.pipe(data.audio, transcriptionOptions(config));
      } catch (error) {
        if (loaded.device !== "webgpu" || (config.device && config.device !== "auto")) {
          throw error;
        }

        webgpuDisabledReason = errorMessage(error);
        clearTranscriber(config);
        postStatus("loading", "WebGPU transcription failed, falling back to WASM", { message: webgpuDisabledReason });
        loaded = await loadTranscriber(config);
        postStatus("transcribing", "Transcribing");
        result = await loaded.pipe(data.audio, transcriptionOptions(config));
      }

      const text = recognizedText(result);
      self.postMessage({
        type: "result",
        id: id,
        text: text,
        device: loaded.device,
      });
    } catch (error) {
      self.postMessage({
        type: "error",
        id: id,
        message: errorMessage(error),
      });
    }
  }

  self.onmessage = function (event) {
    const data = event.data || {};
    if (data.type !== "transcribe") return;
    messageQueue = messageQueue.then(function () {
      return handleTranscribe(data);
    }).catch(function (error) {
      self.postMessage({
        type: "error",
        id: data.id,
        message: errorMessage(error),
      });
    });
  };
})();
