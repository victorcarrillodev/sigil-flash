#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use sigil_flash::logging::init_logging;
use sigil_flash::services::flash::{execute_configure_device, execute_flash_raw};
use std::env;
use std::path::PathBuf;
use std::process;
use tracing::info;

fn main() {
    let guard = match init_logging() {
        Ok(g) => g,
        Err(e) => {
            eprintln!("FALLO CRÍTICO: No se pudo inicializar el sistema de logging: {}", e);
            process::exit(1);
        }
    };
    // Mantener el guard vivo
    let _guard = guard;

    let args: Vec<String> = env::args().collect();

    if args.len() > 1 {
        match args[1].as_str() {
            "--flash-raw" => run_mode_flash_raw(&args[2..]),
            "--configure-device" => run_mode_configure_device(&args[2..]),
            "--help" | "-h" => print_usage_and_exit(0),
            other => {
                eprintln!("Error: Argumento desconocido '{}'", other);
                print_usage_and_exit(1);
            }
        }
    } else {
        // Modo GUI Tauri por defecto
        sigil_flash::run();
    }
}

fn print_usage_and_exit(code: i32) -> ! {
    println!("Uso de SIGIL Flash:");
    println!("  sigil-flash                           Arranca la interfaz gráfica (GUI)");
    println!("  sigil-flash --flash-raw <args...>     Ejecutor privilegiado de flasheo (requiere root)");
    println!("  sigil-flash --configure-device <args> Aplicador de configuración en partición BOOT");
    process::exit(code);
}

fn run_mode_flash_raw(args: &[String]) {
    let mut src = None;
    let mut dest = None;
    let mut progress_file = None;
    let mut offline_packages = None;
    let mut payload = None;
    let mut config_file = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--src" => {
                i += 1;
                if i < args.len() { src = Some(PathBuf::from(&args[i])); }
            }
            "--dest" => {
                i += 1;
                if i < args.len() { dest = Some(PathBuf::from(&args[i])); }
            }
            "--progress-file" => {
                i += 1;
                if i < args.len() { progress_file = Some(PathBuf::from(&args[i])); }
            }
            "--offline-packages" => {
                i += 1;
                if i < args.len() { offline_packages = Some(PathBuf::from(&args[i])); }
            }
            "--payload" => {
                i += 1;
                if i < args.len() { payload = Some(PathBuf::from(&args[i])); }
            }
            "--config-file" => {
                i += 1;
                if i < args.len() { config_file = Some(PathBuf::from(&args[i])); }
            }
            _ => {}
        }
        i += 1;
    }

    if src.is_none() {
        eprintln!("Error: Falta el parámetro obligatorio '--src'");
        process::exit(1);
    }
    if dest.is_none() {
        eprintln!("Error: Falta el parámetro obligatorio '--dest'");
        process::exit(1);
    }
    if progress_file.is_none() {
        eprintln!("Error: Falta el parámetro obligatorio '--progress-file'");
        process::exit(1);
    }
    if offline_packages.is_none() {
        eprintln!("Error: Falta el parámetro obligatorio '--offline-packages'");
        process::exit(1);
    }
    if payload.is_none() {
        eprintln!("Error: Falta el parámetro obligatorio '--payload'");
        process::exit(1);
    }
    if config_file.is_none() {
        eprintln!("Error: Falta el parámetro obligatorio '--config-file'");
        process::exit(1);
    }

    let src = src.unwrap();
    let dest = dest.unwrap();
    let progress_file = progress_file.unwrap();
    let offline_packages = offline_packages.unwrap();
    let payload = payload.unwrap();
    let config_file = config_file.unwrap();

    info!("Iniciando ejecutor privilegiado --flash-raw en {}", dest.display());

    match execute_flash_raw(&src, &dest, &progress_file, &offline_packages, &payload, &config_file) {
        Ok(_) => {
            info!("Flasheo completado exitosamente");
            process::exit(0);
        }
        Err(e) => {
            eprintln!("Error en --flash-raw: {}", e);
            process::exit(1);
        }
    }
}

fn run_mode_configure_device(args: &[String]) {
    let mut device = None;
    let mut config_file = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--device" => {
                i += 1;
                if i < args.len() { device = Some(PathBuf::from(&args[i])); }
            }
            "--config-file" => {
                i += 1;
                if i < args.len() { config_file = Some(PathBuf::from(&args[i])); }
            }
            _ => {}
        }
        i += 1;
    }

    if device.is_none() {
        eprintln!("Error: Falta el parámetro obligatorio '--device'");
        process::exit(1);
    }
    if config_file.is_none() {
        eprintln!("Error: Falta el parámetro obligatorio '--config-file'");
        process::exit(1);
    }

    let device = device.unwrap();
    let config_file = config_file.unwrap();

    info!("Iniciando modo --configure-device sobre {}", device.display());

    match execute_configure_device(&device, &config_file) {
        Ok(_) => {
            info!("Configuración de la partición de arranque completada");
            process::exit(0);
        }
        Err(e) => {
            eprintln!("Error en --configure-device: {}", e);
            process::exit(1);
        }
    }
}
