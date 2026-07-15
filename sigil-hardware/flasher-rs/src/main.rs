use flasher_rs::{model, Engine};
use std::env;
use std::path::PathBuf;
use std::process;

fn print_help() {
    println!("Sigil Flasher Engine — CLI");
    println!("Usage: flasher-rs <command> [options]");
    println!();
    println!("Commands:");
    println!("  plan       Generate a full customization plan");
    println!("  validate   Validate the image, payload, provision, and target");
    println!("  apply      Validate and render the plan (requires --dry-run)");
    println!("  status     Show engine capabilities");
    println!();
    println!("Required options for plan, validate, and apply:");
    println!("  --base-image <PATH>          Immutable .img or .img.xz input");
    println!("  --base-image-sha256 <HEX>    Expected SHA-256 of that exact input file");
    println!("  --payload <DIR>              Generated SIGIL payload directory");
    println!("  --offline-packages <DIR>     Validated local APT repository");
    println!();
    println!("Optional:");
    println!("  --target-device <PATH>       Device reference or regular-file fixture");
    println!("  --provision <PATH>           External sigil_provision.json");
    println!("  --secrets <PATH>             Protected sigil_secrets.json (PIN never in argv)");
    println!("  --dry-run                    Required by apply; guarantees no writes");
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        print_help();
        process::exit(1);
    }

    let command = &args[1];
    let extra: Vec<String> = args[2..].to_vec();

    match command.as_str() {
        "--help" | "-h" | "help" => print_help(),
        "plan" => cmd_plan(&extra),
        "validate" => cmd_validate(&extra),
        "apply" => cmd_apply(&extra),
        "status" => cmd_status(),
        _ => {
            eprintln!("error: unknown command '{command}'");
            eprintln!("Available commands: plan, validate, apply, status");
            process::exit(1);
        }
    }
}

// ── Parsing ──────────────────────────────────────────────────────────────

struct CmdArgs {
    base_image: Option<PathBuf>,
    base_image_sha256: Option<String>,
    payload: Option<PathBuf>,
    offline_packages: Option<PathBuf>,
    target_device: Option<PathBuf>,
    provision: Option<PathBuf>,
    secrets: Option<PathBuf>,
    dry_run: bool,
}

fn parse_cmd_args(args: &[String]) -> Result<CmdArgs, String> {
    let mut base_image = None;
    let mut base_image_sha256 = None;
    let mut payload = None;
    let mut offline_packages = None;
    let mut target_device = None;
    let mut provision = None;
    let mut secrets = None;
    let mut dry_run = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--base-image" => {
                i += 1;
                if i >= args.len() {
                    return Err("missing value for --base-image".into());
                }
                base_image = Some(PathBuf::from(&args[i]));
            }
            "--base-image-sha256" => {
                i += 1;
                if i >= args.len() {
                    return Err("missing value for --base-image-sha256".into());
                }
                base_image_sha256 = Some(args[i].clone());
            }
            "--payload" => {
                i += 1;
                if i >= args.len() {
                    return Err("missing value for --payload".into());
                }
                payload = Some(PathBuf::from(&args[i]));
            }
            "--offline-packages" => {
                i += 1;
                if i >= args.len() {
                    return Err("missing value for --offline-packages".into());
                }
                offline_packages = Some(PathBuf::from(&args[i]));
            }
            "--target-device" => {
                i += 1;
                if i >= args.len() {
                    return Err("missing value for --target-device".into());
                }
                target_device = Some(PathBuf::from(&args[i]));
            }
            "--provision" => {
                i += 1;
                if i >= args.len() {
                    return Err("missing value for --provision".into());
                }
                provision = Some(PathBuf::from(&args[i]));
            }
            "--secrets" => {
                i += 1;
                if i >= args.len() {
                    return Err("missing value for --secrets".into());
                }
                secrets = Some(PathBuf::from(&args[i]));
            }
            "--dry-run" => dry_run = true,
            _ => return Err(format!("unrecognized argument: {}", args[i])),
        }
        i += 1;
    }

    Ok(CmdArgs {
        base_image,
        base_image_sha256,
        payload,
        offline_packages,
        target_device,
        provision,
        secrets,
        dry_run,
    })
}

fn build_engine(cmd: &CmdArgs) -> Result<Engine, String> {
    let base_image = cmd
        .base_image
        .clone()
        .ok_or_else(|| "error: --base-image is required".to_string())?;
    let payload = cmd
        .payload
        .clone()
        .ok_or_else(|| "error: --payload is required".to_string())?;

    let base_image_sha256 = cmd
        .base_image_sha256
        .clone()
        .ok_or_else(|| "error: --base-image-sha256 is required".to_string())?;
    let offline_packages = cmd
        .offline_packages
        .clone()
        .ok_or_else(|| "error: --offline-packages is required".to_string())?;

    let mut engine = Engine::new(base_image, payload)
        .with_base_image_sha256(base_image_sha256)
        .with_offline_packages(offline_packages);
    if let Some(ref dev) = cmd.target_device {
        engine = engine.with_target_device(dev.clone());
    }
    if let Some(ref prov) = cmd.provision {
        engine = engine.with_provision(prov.clone());
    }
    if let Some(ref secrets) = cmd.secrets {
        engine = engine.with_secrets(secrets.clone());
    }
    Ok(engine)
}

// ── Commands ─────────────────────────────────────────────────────────────

fn cmd_plan(args: &[String]) {
    let cmd = parse_cmd_args(args).unwrap_or_else(|e| {
        eprintln!("error: {e}");
        eprintln!("Usage: flasher-rs plan --base-image <PATH> --base-image-sha256 <HEX> --payload <DIR> [options]");
        process::exit(1);
    });
    let engine = build_engine(&cmd).unwrap_or_else(|e| {
        eprintln!("{e}");
        process::exit(1);
    });
    let plan = engine.plan();
    print_plan(&plan);
}

fn cmd_validate(args: &[String]) {
    let cmd = parse_cmd_args(args).unwrap_or_else(|e| {
        eprintln!("error: {e}");
        eprintln!("Usage: flasher-rs validate --base-image <PATH> --base-image-sha256 <HEX> --payload <DIR> [options]");
        process::exit(1);
    });
    let engine = build_engine(&cmd).unwrap_or_else(|e| {
        eprintln!("{e}");
        process::exit(1);
    });
    let result = engine.validate();

    println!("Validation Report:");
    for item in &result.items {
        println!("  [{:>7}] {}", item.severity, item.message);
    }
    if result.valid {
        println!("\nValidation: PASSED");
    } else {
        println!("\nValidation: FAILED");
        process::exit(1);
    }
}

fn cmd_apply(args: &[String]) {
    let cmd = parse_cmd_args(args).unwrap_or_else(|e| {
        eprintln!("error: {e}");
        eprintln!("Usage: flasher-rs apply --base-image <PATH> --base-image-sha256 <HEX> --payload <DIR> [options] --dry-run");
        process::exit(1);
    });

    if !cmd.dry_run {
        eprintln!(
            "error: 'apply' requires --dry-run in Phase 2 (no destructive operations allowed)"
        );
        eprintln!("Usage: flasher-rs apply --base-image <PATH> --base-image-sha256 <HEX> --payload <DIR> [options] --dry-run");
        process::exit(1);
    }

    let engine = build_engine(&cmd).unwrap_or_else(|e| {
        eprintln!("{e}");
        process::exit(1);
    });

    match engine.apply() {
        Ok(plan) => {
            println!("=== APPLY (dry-run) ===");
            print_plan(&plan);
            println!("\n=== NO CHANGES MADE: DRY-RUN ===");
        }
        Err(e) => {
            eprintln!("error: {e}");
            process::exit(1);
        }
    }
}

fn cmd_status() {
    let status = Engine::status();

    println!("Engine:        {}", status.name);
    println!("Version:       {}", status.version);
    println!("Phase:         {}", status.phase);
    println!("Description:   {}", status.description);
    println!();
    println!("Capabilities:");
    for cap in &status.capabilities {
        println!("  {}", cap);
    }
    println!();
    println!("Package requirements: loaded exclusively from the payload canonical contract");
    println!();
    println!("Services to enable ({}):", status.services_enable.len());
    for svc in status.services_enable {
        println!("  - {svc}");
    }
    println!();
    println!("Services to disable ({}):", status.services_disable.len());
    for svc in status.services_disable {
        println!("  - {svc}");
    }
}

// ── Output Formatting ────────────────────────────────────────────────────

fn print_plan(plan: &model::Plan) {
    println!("{}", plan.title);
    for section in &plan.sections {
        println!();
        println!("=== {} ===", section.title);
        for line in &section.lines {
            println!("  {line}");
        }
    }
    println!();
    println!("=== NO CHANGES MADE: DRY-RUN ===");
    println!(
        "  This is a dry-run only model — no files were written, no system changes were made."
    );
}
