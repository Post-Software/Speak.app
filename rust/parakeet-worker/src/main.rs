use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};
use transcribe_rs::engines::parakeet::{ParakeetEngine, ParakeetModelParams};
use transcribe_rs::TranscriptionEngine;

const PARAKEET_MODEL_ID: &str = "parakeet_tdt_0_6b_v3";
const PARAKEET_DISPLAY_NAME: &str = "Parakeet v3 (Default)";
const PARAKEET_SOURCE_REPO: &str = "nemo-parakeet-tdt-0.6b-v3";
const PARAKEET_LAYOUT_VERSION: &str = "handy-v1";
const PARAKEET_FALLBACK_BYTES: i64 = 478_517_071;
const DEFAULT_MODEL_URL: &str =
    "https://github.com/Post-Software/Speak.app/releases/download/model-parakeet-v3/parakeet-v3-int8.tar.gz";
const DEFAULT_MODEL_HASH: &str =
    "43d37191602727524a7d8c6da0eef11c4ba24320f5b4730f1a2497befc2efa77";

#[derive(Debug, Clone)]
struct Cli {
    flags: Vec<String>,
    values: HashMap<String, String>,
}

#[derive(Debug, Serialize)]
struct RuntimePayload {
    model_id: String,
    supported: bool,
    status: String,
    reason: String,
    requires_install: bool,
}

#[derive(Debug, Serialize)]
struct WorkerOkResponse {
    ok: bool,
    text: String,
}

#[derive(Debug, Serialize)]
struct WorkerErrResponse {
    ok: bool,
    error: String,
}

#[derive(Debug, Deserialize)]
struct WorkerRequest {
    audio: Option<String>,
}

#[derive(Debug)]
struct LayoutCheck {
    has_nemo: bool,
    has_encoder: bool,
    has_decoder: bool,
    has_vocab: bool,
}

impl LayoutCheck {
    fn is_valid(&self) -> bool {
        self.has_nemo && self.has_encoder && self.has_decoder && self.has_vocab
    }
}

fn main() {
    if let Err(err) = run() {
        eprintln!("{}", err);
        std::process::exit(4);
    }
}

fn run() -> Result<(), String> {
    let cli = parse_cli(env::args().skip(1).collect())?;

    if cli.has_flag("--model-info") {
        return handle_model_info(&cli);
    }

    if cli.has_flag("--runtime-check") {
        return handle_runtime_check(&cli);
    }

    if cli.has_flag("--ensure-runtime") {
        return handle_ensure_runtime(&cli);
    }

    if cli.has_flag("--download-model") {
        return handle_download_model(&cli);
    }

    if cli.has_flag("--verify-model") {
        return handle_verify_model(&cli);
    }

    if cli.has_flag("--worker") {
        return handle_worker(&cli);
    }

    Err("No command provided. Expected one of --model-info, --runtime-check, --download-model, --verify-model, --worker.".to_string())
}

fn parse_cli(args: Vec<String>) -> Result<Cli, String> {
    let mut flags = Vec::new();
    let mut values = HashMap::new();

    let mut idx = 0;
    while idx < args.len() {
        let token = &args[idx];
        if !token.starts_with("--") {
            return Err(format!("Unexpected argument: {token}"));
        }

        if idx + 1 < args.len() && !args[idx + 1].starts_with("--") {
            values.insert(token.clone(), args[idx + 1].clone());
            idx += 2;
        } else {
            flags.push(token.clone());
            idx += 1;
        }
    }

    Ok(Cli { flags, values })
}

impl Cli {
    fn has_flag(&self, key: &str) -> bool {
        self.flags.iter().any(|entry| entry == key)
    }

    fn value(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(|value| value.as_str())
    }

    fn require_value(&self, key: &str) -> Result<String, String> {
        self.value(key)
            .map(|value| value.to_string())
            .ok_or_else(|| format!("{key} is required"))
    }
}

fn handle_model_info(cli: &Cli) -> Result<(), String> {
    let model_id = cli.require_value("--model-id")?;
    ensure_supported_model_id(&model_id)?;

    let source_url = model_source_url();
    let mut download_bytes = PARAKEET_FALLBACK_BYTES;
    let mut size_source = "fallback";

    if let Some(bytes) = probe_remote_size_with_curl(&source_url) {
        download_bytes = bytes;
        size_source = "exact";
    }

    let payload = json!({
        "id": model_id,
        "repo": PARAKEET_SOURCE_REPO,
        "display_name": PARAKEET_DISPLAY_NAME,
        "download_bytes": download_bytes,
        "size_source": size_source
    });
    print_json(&payload);
    Ok(())
}

fn handle_runtime_check(cli: &Cli) -> Result<(), String> {
    let model_id = cli.require_value("--model-id")?;
    ensure_supported_model_id(&model_id)?;

    let payload = runtime_check_payload(&model_id);
    print_json(&payload);
    Ok(())
}

fn handle_ensure_runtime(cli: &Cli) -> Result<(), String> {
    let model_id = cli.require_value("--model-id")?;
    ensure_supported_model_id(&model_id)?;

    let payload = runtime_check_payload(&model_id);
    if !payload.supported {
        return Err(payload.reason);
    }

    let response = json!({
        "ok": true,
        "model_id": model_id,
        "status": "ready",
        "installed": false,
        "runtime": payload,
    });
    print_json(&response);
    Ok(())
}

fn handle_download_model(cli: &Cli) -> Result<(), String> {
    let model_id = cli.require_value("--model-id")?;
    ensure_supported_model_id(&model_id)?;

    let dest = PathBuf::from(cli.require_value("--dest")?);
    if !dest.exists() {
        fs::create_dir_all(&dest)
            .map_err(|err| format!("Could not create destination root: {}", sanitize_error(err)))?;
    }

    let runtime = runtime_check_payload(&model_id);
    if !runtime.supported {
        return Err(runtime.reason);
    }

    let source_url = model_source_url();
    let staging_dir = dest.join(format!(".staging-{model_id}-{}", unique_suffix()));
    let archive_path = staging_dir.join("parakeet-v3-int8.tar.gz");
    let target_dir = dest.join(&model_id);

    if staging_dir.exists() {
        fs::remove_dir_all(&staging_dir).map_err(|err| sanitize_error(err))?;
    }
    fs::create_dir_all(&staging_dir).map_err(|err| sanitize_error(err))?;

    let result = (|| {
        run_command(
            "/usr/bin/curl",
            &[
                "-fL",
                "--retry",
                "2",
                "--retry-delay",
                "1",
                "--connect-timeout",
                "30",
                "-o",
                archive_path.to_string_lossy().as_ref(),
                source_url.as_str(),
            ],
        )?;

        if let Some(expected_hash) = model_artifact_hash() {
            verify_download_hash(&archive_path, &expected_hash)?;
        }

        run_command(
            "/usr/bin/tar",
            &[
                "-xzf",
                archive_path.to_string_lossy().as_ref(),
                "-C",
                staging_dir.to_string_lossy().as_ref(),
            ],
        )?;

        if archive_path.exists() {
            let _ = fs::remove_file(&archive_path);
        }

        let located_dir = locate_model_dir(&staging_dir)?;
        verify_model_layout(&located_dir)?;

        if target_dir.exists() {
            fs::remove_dir_all(&target_dir).map_err(|err| sanitize_error(err))?;
        }

        if located_dir == staging_dir {
            fs::rename(&staging_dir, &target_dir).map_err(|err| sanitize_error(err))?;
        } else {
            fs::rename(&located_dir, &target_dir).map_err(|err| sanitize_error(err))?;
            let _ = fs::remove_dir_all(&staging_dir);
        }

        Ok::<(), String>(())
    })();

    if let Err(err) = result {
        let _ = fs::remove_dir_all(&staging_dir);
        return Err(format!("Failed to download Parakeet model. {err}"));
    }

    let response = json!({
        "ok": true,
        "path": target_dir,
        "source_url": source_url,
        "artifact_hash": model_artifact_hash(),
        "layout_version": PARAKEET_LAYOUT_VERSION,
    });
    print_json(&response);
    Ok(())
}

fn handle_verify_model(cli: &Cli) -> Result<(), String> {
    let model_id = cli.require_value("--model-id")?;
    ensure_supported_model_id(&model_id)?;

    let model_path = PathBuf::from(cli.require_value("--model-path")?);
    verify_model_layout(&model_path)?;

    let response = json!({
        "ok": true,
        "path": model_path,
    });
    print_json(&response);
    Ok(())
}

fn handle_worker(cli: &Cli) -> Result<(), String> {
    let model_id = cli.require_value("--model-id")?;
    ensure_supported_model_id(&model_id)?;

    if env::var("SPEAK_PARAKEET_WORKER_TEST_MODE")
        .map(|value| value == "1")
        .unwrap_or(false)
    {
        return handle_worker_test_mode();
    }

    let runtime = runtime_check_payload(&model_id);
    if !runtime.supported {
        return Err(setup_required(&runtime.reason));
    }

    let model_path = PathBuf::from(cli.require_value("--model")?);
    verify_model_layout(&model_path).map_err(|err| setup_required(&err))?;

    let mut engine = ParakeetEngine::new();
    engine
        .load_model_with_params(&model_path, ParakeetModelParams::int8())
        .map_err(|err| {
            setup_required(&format!(
                "Failed to initialize Parakeet engine: {}",
                sanitize_error(err)
            ))
        })?;

    let stdin = io::stdin();
    let mut stdout = io::stdout();

    for line_result in stdin.lock().lines() {
        match line_result {
            Ok(line) => {
                if line.trim().is_empty() {
                    continue;
                }

                let request: Result<WorkerRequest, _> = serde_json::from_str(&line);
                let request = match request {
                    Ok(value) => value,
                    Err(_) => {
                        let _ = write_worker_error(&mut stdout, "Invalid request");
                        continue;
                    }
                };

                let audio = match request.audio {
                    Some(path) if !path.trim().is_empty() => path,
                    _ => {
                        let _ = write_worker_error(&mut stdout, "Audio file not found");
                        continue;
                    }
                };

                if !Path::new(&audio).exists() {
                    let _ = write_worker_error(&mut stdout, "Audio file not found");
                    continue;
                }

                match engine.transcribe_file(Path::new(&audio), None) {
                    Ok(result) => {
                        let response = WorkerOkResponse {
                            ok: true,
                            text: result.text.trim().to_string(),
                        };
                        let _ = write_json_line(&mut stdout, &response);
                    }
                    Err(err) => {
                        let _ = write_worker_error(
                            &mut stdout,
                            &format!("Parakeet inference failed: {}", sanitize_error(err)),
                        );
                    }
                }
            }
            Err(err) => {
                return Err(format!("Worker input failed: {}", sanitize_error(err)));
            }
        }
    }

    Ok(())
}

fn handle_worker_test_mode() -> Result<(), String> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    for line_result in stdin.lock().lines() {
        match line_result {
            Ok(line) => {
                if line.trim().is_empty() {
                    continue;
                }

                let request: Result<WorkerRequest, _> = serde_json::from_str(&line);
                let request = match request {
                    Ok(value) => value,
                    Err(_) => {
                        let _ = write_worker_error(&mut stdout, "Invalid request");
                        continue;
                    }
                };

                let audio = match request.audio {
                    Some(path) if !path.trim().is_empty() => path,
                    _ => {
                        let _ = write_worker_error(&mut stdout, "Audio file not found");
                        continue;
                    }
                };

                if !Path::new(&audio).exists() {
                    let _ = write_worker_error(&mut stdout, "Audio file not found");
                    continue;
                }

                let response = WorkerOkResponse {
                    ok: true,
                    text: "test transcription".to_string(),
                };
                let _ = write_json_line(&mut stdout, &response);
            }
            Err(err) => {
                return Err(format!("Worker input failed: {}", sanitize_error(err)));
            }
        }
    }

    Ok(())
}

fn runtime_check_payload(model_id: &str) -> RuntimePayload {
    #[cfg(target_os = "macos")]
    {
        #[cfg(target_arch = "aarch64")]
        {
            return RuntimePayload {
                model_id: model_id.to_string(),
                supported: true,
                status: "ok".to_string(),
                reason: String::new(),
                requires_install: false,
            };
        }

        #[cfg(not(target_arch = "aarch64"))]
        {
            return RuntimePayload {
                model_id: model_id.to_string(),
                supported: false,
                status: "unsupported".to_string(),
                reason: "Parakeet v3 Rust runtime is currently optimized for Apple Silicon. Use Medium Whisper on Intel Macs.".to_string(),
                requires_install: false,
            };
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        RuntimePayload {
            model_id: model_id.to_string(),
            supported: false,
            status: "unsupported".to_string(),
            reason: "Parakeet v3 Rust runtime is currently supported on macOS only.".to_string(),
            requires_install: false,
        }
    }
}

fn ensure_supported_model_id(model_id: &str) -> Result<(), String> {
    if model_id != PARAKEET_MODEL_ID {
        return Err(format!(
            "Unsupported model id for Parakeet worker: {model_id}"
        ));
    }
    Ok(())
}

fn model_source_url() -> String {
    env::var("SPEAK_PARAKEET_MODEL_URL").unwrap_or_else(|_| DEFAULT_MODEL_URL.to_string())
}

fn model_artifact_hash() -> Option<String> {
    env::var("SPEAK_PARAKEET_MODEL_HASH")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| Some(DEFAULT_MODEL_HASH.to_string()))
}

fn verify_download_hash(archive_path: &Path, expected_hash: &str) -> Result<(), String> {
    let output = Command::new("/usr/bin/shasum")
        .args(["-a", "256", archive_path.to_string_lossy().as_ref()])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|err| format!("Failed to verify Parakeet model download: {}", sanitize_error(err)))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let summary = if !stderr.is_empty() { stderr } else { stdout };
        return Err(format!(
            "Failed to verify Parakeet model download: {}",
            compact_message(&summary, 320)
        ));
    }

    let actual_hash = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let expected_hash = expected_hash.trim().to_ascii_lowercase();

    if actual_hash != expected_hash {
        return Err("Downloaded Parakeet model hash mismatch.".to_string());
    }

    Ok(())
}

fn probe_remote_size_with_curl(url: &str) -> Option<i64> {
    let head_output = Command::new("/usr/bin/curl")
        .args(["-sIL", "--max-time", "20", "--retry", "1", url])
        .output()
        .ok()?;

    if head_output.status.success() {
        let stdout = String::from_utf8_lossy(&head_output.stdout);
        if let Some(bytes) = parse_remote_size_from_headers(&stdout) {
            return Some(bytes);
        }
    }

    // Some hosts omit useful headers on HEAD; do a 1-byte range GET and read response headers.
    let range_output = Command::new("/usr/bin/curl")
        .args([
            "-sL",
            "--max-time",
            "20",
            "--retry",
            "1",
            "--range",
            "0-0",
            "-D",
            "-",
            "-o",
            "/dev/null",
            url,
        ])
        .output()
        .ok()?;

    if !range_output.status.success() {
        return None;
    }

    let headers = String::from_utf8_lossy(&range_output.stdout);
    parse_remote_size_from_headers(&headers)
}

fn parse_remote_size_from_headers(headers: &str) -> Option<i64> {
    for line in headers.lines().rev() {
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("content-length:") {
            if let Some(value) = line.split(':').nth(1).map(|value| value.trim()) {
                if let Ok(parsed) = value.parse::<i64>() {
                    return Some(parsed);
                }
            }
        }
        if lower.starts_with("content-range:") {
            if let Some(total) = line.split('/').nth(1).map(|value| value.trim()) {
                if let Ok(parsed) = total.parse::<i64>() {
                    return Some(parsed);
                }
            }
        }
    }
    None
}

fn locate_model_dir(root: &Path) -> Result<PathBuf, String> {
    if !root.exists() {
        return Err("Downloaded model directory is missing.".to_string());
    }

    if verify_model_layout(root).is_ok() {
        return Ok(root.to_path_buf());
    }

    let mut stack = vec![root.to_path_buf()];
    while let Some(current) = stack.pop() {
        let entries = match fs::read_dir(&current) {
            Ok(entries) => entries,
            Err(_) => continue,
        };

        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }

            if verify_model_layout(&path).is_ok() {
                return Ok(path);
            }
            stack.push(path);
        }
    }

    Err("Could not locate downloaded Parakeet model artifacts (expected nemo*.onnx, encoder-model*.onnx, decoder_joint-model*.onnx, vocab.txt).".to_string())
}

fn verify_model_layout(model_path: &Path) -> Result<(), String> {
    if !model_path.is_dir() {
        return Err("Downloaded model directory is missing.".to_string());
    }

    let check = inspect_layout(model_path)?;
    if !check.is_valid() {
        return Err("Could not locate downloaded Parakeet model artifacts (expected nemo*.onnx, encoder-model*.onnx, decoder_joint-model*.onnx, vocab.txt).".to_string());
    }

    Ok(())
}

fn inspect_layout(model_path: &Path) -> Result<LayoutCheck, String> {
    let mut check = LayoutCheck {
        has_nemo: false,
        has_encoder: false,
        has_decoder: false,
        has_vocab: false,
    };

    let entries = fs::read_dir(model_path).map_err(|err| sanitize_error(err))?;
    for entry in entries {
        let entry = entry.map_err(|err| sanitize_error(err))?;
        let file_name = entry.file_name();
        let lower_name = file_name.to_string_lossy().to_ascii_lowercase();

        if lower_name == "vocab.txt" {
            check.has_vocab = true;
        }
        if lower_name.starts_with("nemo") && lower_name.ends_with(".onnx") {
            check.has_nemo = true;
        }
        if lower_name.starts_with("encoder-model") && lower_name.ends_with(".onnx") {
            check.has_encoder = true;
        }
        if lower_name.starts_with("decoder_joint-model") && lower_name.ends_with(".onnx") {
            check.has_decoder = true;
        }
    }

    Ok(check)
}

fn run_command(program: &str, args: &[&str]) -> Result<(), String> {
    let output = Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|err| format!("Failed to execute {program}: {}", sanitize_error(err)))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let summary = if !stderr.is_empty() { stderr } else { stdout };

    if summary.is_empty() {
        return Err(format!("{program} exited with status {}", output.status));
    }

    Err(compact_message(&summary, 320))
}

fn write_worker_error(stdout: &mut dyn Write, error: &str) -> Result<(), String> {
    let response = WorkerErrResponse {
        ok: false,
        error: compact_message(error, 500),
    };
    write_json_line(stdout, &response)
}

fn write_json_line<T: Serialize>(stdout: &mut dyn Write, payload: &T) -> Result<(), String> {
    let encoded = serde_json::to_string(payload).map_err(|err| sanitize_error(err))?;
    stdout
        .write_all(encoded.as_bytes())
        .map_err(|err| sanitize_error(err))?;
    stdout.write_all(b"\n").map_err(|err| sanitize_error(err))?;
    stdout.flush().map_err(|err| sanitize_error(err))
}

fn print_json<T: Serialize>(payload: &T) {
    let encoded = serde_json::to_string(payload).unwrap_or_else(|_| "{}".to_string());
    println!("{}", encoded);
}

fn unique_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("{}-{}", std::process::id(), nanos)
}

fn setup_required(message: &str) -> String {
    format!("setup_required: {message}")
}

fn compact_message(message: &str, max_chars: usize) -> String {
    let trimmed = message.trim();
    if trimmed.len() <= max_chars {
        return trimmed.to_string();
    }

    let mut out = trimmed.chars().take(max_chars).collect::<String>();
    out.push('…');
    out
}

fn sanitize_error<E: std::fmt::Display>(err: E) -> String {
    compact_message(&err.to_string(), 320)
}
