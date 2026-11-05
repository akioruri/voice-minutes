use clap::Parser;

use voice_minutes::cmd::{Cli, Command, run_split, run_summarize, run_transcribe};
use voice_minutes::config::AppConfig;
use voice_minutes::error::AppError;

fn main() {
    let cli = Cli::parse();
    let cfg = match AppConfig::load(cli.config.as_deref()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {}", e);
            std::process::exit(e.exit_code());
        }
    };

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("failed to build tokio runtime");
    let result: Result<(), AppError> = match &cli.command {
        Command::Split(args) => {
            // `split` is sync, but we still call it from inside the runtime
            // so the binary has a single exit point.
            runtime.block_on(async { run_split(&cfg, args) })
        }
        Command::Transcribe(args) => {
            runtime.block_on(async { run_transcribe(&cfg, args).await.map(|_| ()) })
        }
        Command::Summarize(args) => runtime.block_on(async { run_summarize(&cfg, args).await }),
    };
    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(e.exit_code());
    }
}
