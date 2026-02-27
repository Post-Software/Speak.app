use serde_json::Value;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn worker_bin() -> &'static str {
    env!("CARGO_BIN_EXE_parakeet-worker")
}

fn fixture_path(parts: &[&str]) -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("..");
    path.push("..");
    for part in parts {
        path.push(part);
    }
    path
}

fn last_json_line(stdout: &[u8]) -> Value {
    let text = String::from_utf8_lossy(stdout);
    for line in text.lines().rev() {
        if let Ok(value) = serde_json::from_str::<Value>(line) {
            return value;
        }
    }
    panic!("no JSON found in stdout: {text}");
}

#[test]
fn runtime_check_returns_expected_json() {
    let output = Command::new(worker_bin())
        .args(["--runtime-check", "--model-id", "parakeet_tdt_0_6b_v3"])
        .output()
        .expect("runtime-check command should execute");

    assert!(output.status.success());
    let payload = last_json_line(&output.stdout);
    assert_eq!(payload["model_id"], "parakeet_tdt_0_6b_v3");
    assert!(payload.get("supported").is_some());
    assert!(payload.get("status").is_some());
}

#[test]
fn model_info_returns_expected_json() {
    let output = Command::new(worker_bin())
        .args(["--model-info", "--model-id", "parakeet_tdt_0_6b_v3"])
        .output()
        .expect("model-info command should execute");

    assert!(output.status.success());
    let payload = last_json_line(&output.stdout);
    assert_eq!(payload["id"], "parakeet_tdt_0_6b_v3");
    assert!(payload.get("download_bytes").is_some());
}

#[test]
fn verify_model_succeeds_for_valid_layout() {
    let valid_dir = fixture_path(&["tests", "fixtures", "models", "parakeet_valid"]);
    let output = Command::new(worker_bin())
        .args([
            "--verify-model",
            "--model-id",
            "parakeet_tdt_0_6b_v3",
            "--model-path",
            valid_dir.to_string_lossy().as_ref(),
        ])
        .output()
        .expect("verify-model command should execute");

    assert!(output.status.success());
    let payload = last_json_line(&output.stdout);
    assert_eq!(payload["ok"], true);
}

#[test]
fn verify_model_fails_for_invalid_layout() {
    let invalid_dir = fixture_path(&["tests", "fixtures", "models", "parakeet_invalid"]);
    let output = Command::new(worker_bin())
        .args([
            "--verify-model",
            "--model-id",
            "parakeet_tdt_0_6b_v3",
            "--model-path",
            invalid_dir.to_string_lossy().as_ref(),
        ])
        .output()
        .expect("verify-model command should execute");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("Could not locate downloaded Parakeet model artifacts"));
}

#[test]
fn worker_returns_error_json_for_invalid_request() {
    let mut process = Command::new(worker_bin())
        .env("SPEAK_PARAKEET_WORKER_TEST_MODE", "1")
        .args([
            "--worker",
            "--model-id",
            "parakeet_tdt_0_6b_v3",
            "--model",
            fixture_path(&["tests", "fixtures", "models", "parakeet_valid"]).to_string_lossy().as_ref(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("worker should spawn");

    {
        let stdin = process.stdin.as_mut().expect("stdin must exist");
        writeln!(stdin, "{{\"bad\":\"payload\"}}")
            .expect("write request");
    }

    let output = process.wait_with_output().expect("wait for worker output");
    let payload = last_json_line(&output.stdout);
    assert_eq!(payload["ok"], false);
    assert_eq!(payload["error"], "Audio file not found");
}

#[test]
fn worker_returns_error_json_for_malformed_request() {
    let mut process = Command::new(worker_bin())
        .env("SPEAK_PARAKEET_WORKER_TEST_MODE", "1")
        .args([
            "--worker",
            "--model-id",
            "parakeet_tdt_0_6b_v3",
            "--model",
            fixture_path(&["tests", "fixtures", "models", "parakeet_valid"]).to_string_lossy().as_ref(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("worker should spawn");

    {
        let stdin = process.stdin.as_mut().expect("stdin must exist");
        writeln!(stdin, "not-json").expect("write request");
    }

    let output = process.wait_with_output().expect("wait for worker output");
    let payload = last_json_line(&output.stdout);
    assert_eq!(payload["ok"], false);
    assert_eq!(payload["error"], "Invalid request");
}
