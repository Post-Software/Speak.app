use std::collections::HashMap;
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail, Context, Result};
use burn::backend::Wgpu;
use burn::prelude::ElementConversion;
use burn::tensor::{Int, Tensor, TensorData};
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use voxtral_mini_realtime::audio::{
    chunk::{chunk_audio, needs_chunking, AudioChunk, ChunkConfig},
    mel::{MelConfig, MelSpectrogram},
    pad::{pad_audio, PadConfig},
    resample::resample_to_16k,
    AudioBuffer,
};
use voxtral_mini_realtime::models::time_embedding::TimeEmbedding;
use voxtral_mini_realtime::tokenizer::VoxtralTokenizer;

type Backend = Wgpu;
type Device = <Backend as burn::tensor::backend::Backend>::Device;

const FAST_ID: &str = "voxtral_q4_fast";
const QUALITY_ID: &str = "voxtral_full_quality";

const FAST_REPO: &str = "TrevorJS/voxtral-mini-realtime-gguf";
const FAST_GGUF: &str = "voxtral-q4.gguf";
const FAST_TOKENIZER: &str = "tekken.json";

const QUALITY_REPO: &str = "mistralai/Voxtral-Mini-4B-Realtime-2602";
const QUALITY_WEIGHTS_PRIMARY: &str = "model.safetensors";
const QUALITY_WEIGHTS_ALT: &str = "consolidated.safetensors";
const QUALITY_CONFIG: &str = "params.json";
const QUALITY_TOKENIZER: &str = "tekken.json";

#[derive(Parser)]
#[command(name = "speak-transcriber")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    ModelInfo {
        #[arg(long)]
        id: String,
    },
    Download {
        #[arg(long)]
        id: String,
        #[arg(long)]
        dest: PathBuf,
    },
    Delete {
        #[arg(long)]
        id: String,
        #[arg(long)]
        dest: PathBuf,
    },
    Worker {
        #[arg(long)]
        id: String,
        #[arg(long)]
        dest: PathBuf,
    },
}

#[derive(Clone, Copy)]
enum ModelKind {
    Fast,
    Quality,
}

impl ModelKind {
    fn from_id(id: &str) -> Result<Self> {
        match id {
            FAST_ID => Ok(Self::Fast),
            QUALITY_ID => Ok(Self::Quality),
            _ => bail!("Unknown model id '{id}'"),
        }
    }

    fn repo(self) -> &'static str {
        match self {
            Self::Fast => FAST_REPO,
            Self::Quality => QUALITY_REPO,
        }
    }

    fn display(self) -> &'static str {
        match self {
            Self::Fast => "Fast (Q4)",
            Self::Quality => "Quality (Full Precision)",
        }
    }

    fn estimated_runtime_memory_bytes(self) -> u64 {
        match self {
            Self::Fast => 700 * 1024 * 1024,
            Self::Quality => 9 * 1024 * 1024 * 1024,
        }
    }

    fn required_files(self, tree: &HashMap<String, u64>) -> Result<Vec<(&'static str, u64)>> {
        match self {
            Self::Fast => {
                let gguf = tree
                    .get(FAST_GGUF)
                    .copied()
                    .ok_or_else(|| anyhow!("Model file missing from remote repo: {FAST_GGUF}"))?;
                let tokenizer = tree
                    .get(FAST_TOKENIZER)
                    .copied()
                    .ok_or_else(|| anyhow!("Tokenizer missing from remote repo: {FAST_TOKENIZER}"))?;
                Ok(vec![(FAST_GGUF, gguf), (FAST_TOKENIZER, tokenizer)])
            }
            Self::Quality => {
                let chosen_weight = if tree.contains_key(QUALITY_WEIGHTS_PRIMARY) {
                    QUALITY_WEIGHTS_PRIMARY
                } else {
                    QUALITY_WEIGHTS_ALT
                };
                let weight_size = tree
                    .get(chosen_weight)
                    .copied()
                    .ok_or_else(|| anyhow!("Weight file missing from remote repo"))?;
                let tokenizer = tree
                    .get(QUALITY_TOKENIZER)
                    .copied()
                    .ok_or_else(|| anyhow!("Tokenizer missing from remote repo: {QUALITY_TOKENIZER}"))?;
                let mut files = vec![(chosen_weight, weight_size), (QUALITY_TOKENIZER, tokenizer)];
                if let Some(size) = tree.get("config.json").copied() {
                    files.push(("config.json", size));
                }
                if let Some(size) = tree.get(QUALITY_CONFIG).copied() {
                    files.push((QUALITY_CONFIG, size));
                }
                if let Some(size) = tree.get("processor_config.json").copied() {
                    files.push(("processor_config.json", size));
                }
                if let Some(size) = tree.get("generation_config.json").copied() {
                    files.push(("generation_config.json", size));
                }
                Ok(files)
            }
        }
    }
}

#[derive(Serialize)]
struct ModelInfoOut {
    #[serde(rename = "type")]
    kind: &'static str,
    ok: bool,
    id: String,
    repo: String,
    display_name: String,
    download_bytes: u64,
    estimated_runtime_memory_bytes: u64,
}

#[derive(Serialize)]
struct ProgressOut<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    stage: &'a str,
    pct: u8,
    message: String,
}

#[derive(Serialize)]
struct WorkerReadyOut {
    #[serde(rename = "type")]
    kind: &'static str,
    ok: bool,
    backend: String,
    fallback_reason: Option<String>,
}

#[derive(Serialize)]
struct ResultOut {
    #[serde(rename = "type")]
    kind: &'static str,
    ok: bool,
    text: Option<String>,
    error: Option<String>,
    backend: String,
}

#[derive(Deserialize)]
struct WorkerRequest {
    #[serde(rename = "type")]
    kind: String,
    audio_path: String,
}

#[derive(Deserialize)]
struct HfTreeNode {
    path: String,
    size: Option<u64>,
}

#[derive(Clone)]
struct RuntimePaths {
    root: PathBuf,
}

impl RuntimePaths {
    fn for_model(dest: &Path, model_id: &str) -> Self {
        Self {
            root: dest.join(model_id),
        }
    }

    fn ensure(&self) -> Result<()> {
        fs::create_dir_all(&self.root).context("failed to create model directory")
    }

    fn file(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }
}

#[allow(clippy::large_enum_variant)]
enum Model {
    F32(voxtral_mini_realtime::models::voxtral::VoxtralModel<Backend>),
    Q4(voxtral_mini_realtime::gguf::model::Q4VoxtralModel),
}

struct TranscriptionEngine {
    model: Model,
    tokenizer: VoxtralTokenizer,
    mel_extractor: MelSpectrogram,
    pad_config: PadConfig,
    chunk_config: ChunkConfig,
    time_embedding: TimeEmbedding,
    device: Device,
}

impl TranscriptionEngine {
    fn load(model_kind: ModelKind, paths: &RuntimePaths) -> Result<Self> {
        let device: Device = Default::default();
        match model_kind {
            ModelKind::Fast => {
                let gguf_path = paths.file(FAST_GGUF);
                let tokenizer_path = paths.file(FAST_TOKENIZER);
                if !gguf_path.exists() {
                    bail!("Fast model not found at {}", gguf_path.display());
                }
                if !tokenizer_path.exists() {
                    bail!("Tokenizer not found at {}", tokenizer_path.display());
                }
                let mut loader = voxtral_mini_realtime::gguf::loader::Q4ModelLoader::from_file(&gguf_path)
                    .context("failed to open GGUF file")?;
                let model = Model::Q4(loader.load(&device).context("failed to load Q4 model")?);
                Self::build(model, &tokenizer_path, device)
            }
            ModelKind::Quality => {
                let weights = if paths.file(QUALITY_WEIGHTS_PRIMARY).exists() {
                    paths.file(QUALITY_WEIGHTS_PRIMARY)
                } else {
                    paths.file(QUALITY_WEIGHTS_ALT)
                };
                let tokenizer_path = paths.file(QUALITY_TOKENIZER);
                if !weights.exists() {
                    bail!("Quality model weights not found under {}", paths.root.display());
                }
                if !tokenizer_path.exists() {
                    bail!("Tokenizer not found at {}", tokenizer_path.display());
                }
                let loader = voxtral_mini_realtime::models::loader::VoxtralModelLoader::from_file(&weights)
                    .context("failed to open model weights")?;
                let model = Model::F32(loader.load(&device).context("failed to load quality model")?);
                Self::build(model, &tokenizer_path, device)
            }
        }
    }

    fn build(model: Model, tokenizer_path: &Path, device: Device) -> Result<Self> {
        let tokenizer = VoxtralTokenizer::from_file(tokenizer_path).context("failed to load tokenizer")?;
        Ok(Self {
            model,
            tokenizer,
            mel_extractor: MelSpectrogram::new(MelConfig::voxtral()),
            pad_config: PadConfig::voxtral(),
            chunk_config: ChunkConfig::voxtral().with_max_frames(1200),
            time_embedding: TimeEmbedding::new(3072),
            device,
        })
    }

    fn transcribe_wav_path(&self, audio_path: &Path) -> Result<String> {
        let (samples, sample_rate) = load_wav(audio_path)?;
        self.transcribe(&samples, sample_rate)
    }

    fn transcribe(&self, samples: &[f32], sample_rate: u32) -> Result<String> {
        if samples.is_empty() {
            return Ok(String::new());
        }

        let mut audio = AudioBuffer::new(samples.to_vec(), sample_rate);
        if sample_rate != 16000 {
            audio = resample_to_16k(&audio).context("failed to resample audio")?;
        }

        audio.peak_normalize(0.95);
        let t_embed = self.time_embedding.embed::<Backend>(6.0, &self.device);

        let chunks = if needs_chunking(audio.samples.len(), &self.chunk_config) {
            chunk_audio(&audio.samples, &self.chunk_config)
        } else {
            vec![AudioChunk {
                samples: audio.samples.clone(),
                start_sample: 0,
                end_sample: audio.samples.len(),
                index: 0,
                is_last: true,
            }]
        };

        let mut texts = Vec::new();
        for chunk in &chunks {
            let chunk_audio = AudioBuffer::new(chunk.samples.clone(), audio.sample_rate);
            let mel_tensor = self.mel_tensor_from_audio(&chunk_audio)?;
            let generated = match &self.model {
                Model::Q4(model) => model.transcribe_streaming(mel_tensor, t_embed.clone()),
                Model::F32(model) => self.transcribe_f32(model, mel_tensor, t_embed.clone())?,
            };
            let text = self.decode_tokens(&generated)?;
            if !text.trim().is_empty() {
                texts.push(text.trim().to_string());
            }
        }

        Ok(texts.join(" "))
    }

    fn mel_tensor_from_audio(&self, audio: &AudioBuffer) -> Result<Tensor<Backend, 3>> {
        let padded = pad_audio(audio, &self.pad_config);
        let mel = self.mel_extractor.compute_log(&padded.samples);
        let n_frames = mel.len();
        let n_mels = if n_frames > 0 { mel[0].len() } else { 0 };

        if n_frames == 0 {
            bail!("audio too short to produce mel frames");
        }

        let mut mel_transposed = vec![vec![0.0f32; n_frames]; n_mels];
        for (frame_idx, frame) in mel.iter().enumerate() {
            for (mel_idx, &val) in frame.iter().enumerate() {
                mel_transposed[mel_idx][frame_idx] = val;
            }
        }
        let mel_flat: Vec<f32> = mel_transposed.into_iter().flatten().collect();

        Ok(Tensor::from_data(
            TensorData::new(mel_flat, [1, n_mels, n_frames]),
            &self.device,
        ))
    }

    fn decode_tokens(&self, generated: &[i32]) -> Result<String> {
        let text_tokens: Vec<u32> = generated
            .iter()
            .filter(|&&t| t >= 1000)
            .map(|&t| t as u32)
            .collect();
        self.tokenizer
            .decode(&text_tokens)
            .context("failed to decode tokens")
    }

    fn transcribe_f32(
        &self,
        model: &voxtral_mini_realtime::models::voxtral::VoxtralModel<Backend>,
        mel_tensor: Tensor<Backend, 3>,
        t_embed: Tensor<Backend, 3>,
    ) -> Result<Vec<i32>> {
        let audio_embeds = model.encode_audio(mel_tensor);
        let seq_len = audio_embeds.dims()[1];
        let d_model = audio_embeds.dims()[2];

        const PREFIX_LEN: usize = 38;
        const BOS_TOKEN: i32 = 1;
        const STREAMING_PAD: i32 = 32;

        if seq_len < PREFIX_LEN {
            return Ok(Vec::new());
        }

        let mut decoder_cache = model.create_decoder_cache_preallocated(seq_len, &self.device);

        let mut prefix: Vec<i32> = vec![BOS_TOKEN];
        prefix.extend(std::iter::repeat_n(STREAMING_PAD, PREFIX_LEN - 1));

        let prefix_tensor = Tensor::<Backend, 2, Int>::from_data(
            TensorData::new(prefix.clone(), [1, PREFIX_LEN]),
            &self.device,
        );
        let prefix_text_embeds = model.decoder().embed_tokens(prefix_tensor);

        let prefix_audio = audio_embeds
            .clone()
            .slice([0..1, 0..PREFIX_LEN, 0..d_model]);

        let prefix_inputs = prefix_audio + prefix_text_embeds;
        let hidden = model.decoder().forward_hidden_with_cache(
            prefix_inputs,
            t_embed.clone(),
            &mut decoder_cache,
        );
        let logits = model.decoder().lm_head(hidden);

        let vocab_size = logits.dims()[2];
        let last_logits = logits.slice([0..1, (PREFIX_LEN - 1)..PREFIX_LEN, 0..vocab_size]);
        let first_pred = last_logits.argmax(2);
        let first_token: i32 = first_pred.into_scalar().elem();

        let mut generated = prefix;
        generated.push(first_token);

        for pos in PREFIX_LEN + 1..seq_len {
            let new_token = generated[pos - 1];
            let token_tensor = Tensor::<Backend, 2, Int>::from_data(
                TensorData::new(vec![new_token], [1, 1]),
                &self.device,
            );
            let text_embed = model.decoder().embed_tokens(token_tensor);

            let audio_pos = audio_embeds
                .clone()
                .slice([0..1, (pos - 1)..pos, 0..d_model]);

            let input = audio_pos + text_embed;
            let hidden = model.decoder().forward_hidden_with_cache(
                input,
                t_embed.clone(),
                &mut decoder_cache,
            );
            let logits = model.decoder().lm_head(hidden);

            let pred = logits.argmax(2);
            let next_token: i32 = pred.into_scalar().elem();
            generated.push(next_token);
        }

        Ok(generated.into_iter().skip(PREFIX_LEN).collect())
    }
}

fn load_wav(path: &Path) -> Result<(Vec<f32>, u32)> {
    let mut reader = hound::WavReader::open(path)
        .with_context(|| format!("failed to open wav file: {}", path.display()))?;
    let spec = reader.spec();
    let sample_rate = spec.sample_rate;
    let channels = spec.channels.max(1) as usize;

    let mut mono = Vec::new();
    match spec.sample_format {
        hound::SampleFormat::Float => {
            let mut frame = Vec::with_capacity(channels);
            for sample in reader.samples::<f32>() {
                frame.push(sample?);
                if frame.len() == channels {
                    mono.push(frame.iter().copied().sum::<f32>() / channels as f32);
                    frame.clear();
                }
            }
        }
        hound::SampleFormat::Int => {
            if spec.bits_per_sample <= 16 {
                let max = i16::MAX as f32;
                let mut frame = Vec::with_capacity(channels);
                for sample in reader.samples::<i16>() {
                    frame.push(sample? as f32 / max);
                    if frame.len() == channels {
                        mono.push(frame.iter().copied().sum::<f32>() / channels as f32);
                        frame.clear();
                    }
                }
            } else {
                let max = i32::MAX as f32;
                let mut frame = Vec::with_capacity(channels);
                for sample in reader.samples::<i32>() {
                    frame.push(sample? as f32 / max);
                    if frame.len() == channels {
                        mono.push(frame.iter().copied().sum::<f32>() / channels as f32);
                        frame.clear();
                    }
                }
            }
        }
    }

    Ok((mono, sample_rate))
}

fn write_json<T: Serialize>(value: &T) -> Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, value)?;
    out.write_all(b"\n")?;
    out.flush()?;
    Ok(())
}

fn fetch_tree_size_index(repo: &str) -> Result<HashMap<String, u64>> {
    let url = format!(
        "https://huggingface.co/api/models/{}/tree/main?recursive=1",
        repo
    );
    let response = ureq::get(&url)
        .call()
        .with_context(|| format!("failed to fetch model tree from {url}"))?;
    let nodes: Vec<HfTreeNode> = response
        .into_json()
        .context("failed to parse model tree JSON")?;

    let mut by_path = HashMap::new();
    for node in nodes {
        if let Some(size) = node.size {
            by_path.insert(node.path, size);
        }
    }
    Ok(by_path)
}

fn model_info(id: String) -> Result<()> {
    let model = ModelKind::from_id(&id)?;
    let tree = fetch_tree_size_index(model.repo())?;
    let files = model.required_files(&tree)?;
    let bytes = files.iter().map(|(_, size)| *size).sum();

    write_json(&ModelInfoOut {
        kind: "model_info",
        ok: true,
        id,
        repo: model.repo().to_string(),
        display_name: model.display().to_string(),
        download_bytes: bytes,
        estimated_runtime_memory_bytes: model.estimated_runtime_memory_bytes(),
    })
}

fn download_model(id: String, dest: PathBuf) -> Result<()> {
    let model = ModelKind::from_id(&id)?;
    let tree = fetch_tree_size_index(model.repo())?;
    let files = model.required_files(&tree)?;
    let total_steps = files.len().max(1);

    let paths = RuntimePaths::for_model(&dest, &id);
    paths.ensure()?;

    write_json(&ProgressOut {
        kind: "progress",
        stage: "download",
        pct: 0,
        message: format!("Preparing download for {}", model.display()),
    })?;

    let api = hf_hub::api::sync::Api::new().context("failed to create HuggingFace API")?;
    let repo = api.model(model.repo().to_string());

    for (idx, (file_name, _)) in files.iter().enumerate() {
        let cached_path = repo
            .get(file_name)
            .with_context(|| format!("failed to download {file_name}"))?;
        let target = paths.file(file_name);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&cached_path, &target).with_context(|| {
            format!(
                "failed to copy {} to {}",
                cached_path.display(),
                target.display()
            )
        })?;

        let pct = (((idx + 1) as f64 / total_steps as f64) * 100.0).round() as u8;
        write_json(&ProgressOut {
            kind: "progress",
            stage: "download",
            pct,
            message: format!("Downloaded {}", file_name),
        })?;
    }

    Ok(())
}

fn delete_model(id: String, dest: PathBuf) -> Result<()> {
    let model_dir = RuntimePaths::for_model(&dest, &id).root;
    if model_dir.exists() {
        fs::remove_dir_all(&model_dir)
            .with_context(|| format!("failed to remove {}", model_dir.display()))?;
    }
    Ok(())
}

fn detect_backend() -> (String, Option<String>) {
    let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
        backends: wgpu::Backends::METAL,
        flags: wgpu::InstanceFlags::default(),
        backend_options: Default::default(),
        memory_budget_thresholds: Default::default(),
    });

    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        force_fallback_adapter: false,
        compatible_surface: None,
    }));

    if adapter.is_ok() {
        ("metal".to_string(), None)
    } else {
        (
            "cpu".to_string(),
            Some("no_metal_adapter".to_string()),
        )
    }
}

fn worker(id: String, dest: PathBuf) -> Result<()> {
    let model = ModelKind::from_id(&id)?;
    let paths = RuntimePaths::for_model(&dest, &id);

    let (backend, fallback_reason) = detect_backend();
    if backend == "cpu" {
        std::env::set_var("WGPU_FORCE_FALLBACK_ADAPTER", "1");
    }
    let engine = TranscriptionEngine::load(model, &paths)?;

    write_json(&WorkerReadyOut {
        kind: "worker_ready",
        ok: true,
        backend: backend.clone(),
        fallback_reason,
    })?;

    for line in io::stdin().lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let req: WorkerRequest = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(err) => {
                write_json(&ResultOut {
                    kind: "result",
                    ok: false,
                    text: None,
                    error: Some(format!("invalid request: {err}")),
                    backend: backend.clone(),
                })?;
                continue;
            }
        };

        if req.kind != "transcribe" {
            write_json(&ResultOut {
                kind: "result",
                ok: false,
                text: None,
                error: Some("unsupported request type".to_string()),
                backend: backend.clone(),
            })?;
            continue;
        }

        write_json(&ProgressOut {
            kind: "progress",
            stage: "transcribe",
            pct: 0,
            message: "Transcribing audio".to_string(),
        })?;

        let result = engine.transcribe_wav_path(Path::new(&req.audio_path));
        match result {
            Ok(text) => {
                write_json(&ResultOut {
                    kind: "result",
                    ok: true,
                    text: Some(text),
                    error: None,
                    backend: backend.clone(),
                })?;
            }
            Err(err) => {
                write_json(&ResultOut {
                    kind: "result",
                    ok: false,
                    text: None,
                    error: Some(err.to_string()),
                    backend: backend.clone(),
                })?;
            }
        }
    }

    Ok(())
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::ModelInfo { id } => model_info(id),
        Command::Download { id, dest } => download_model(id, dest),
        Command::Delete { id, dest } => delete_model(id, dest),
        Command::Worker { id, dest } => worker(id, dest),
    }
}
