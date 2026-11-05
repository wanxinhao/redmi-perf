//! redmi-perf - control the Xiaomi MIFS platform performance mode.
//!
//! Thin userspace wrapper around the sysfs interface exported by the
//! `redmi_perf_wmi` kernel module.  The module does the actual WMI call to
//! the Xiaomi "MiInterface" firmware method; this binary only parses
//! arguments and formats output.

use std::env;
use std::fs;
use std::io::Write;
use std::process::ExitCode;

const SYSFS: &str = "/sys/class/redmi_perf";
const PARAMS: &str = "/sys/module/redmi_perf_wmi/parameters";

const USAGE: &str = "\
redmi-perf - Xiaomi platform performance mode control

USAGE:
    redmi-perf <COMMAND>

COMMANDS:
    get              show the current performance mode
    set <MODE>       switch mode (performance|balanced|quiet|full-speed)
    list             list the available modes
    status           show the last firmware status and call parameters
    psu              show the power source (DC barrel jack vs USB-C)
    raw <HEX>        send a raw InData buffer and print the raw OutData
    raw              print the OutData of the previous call
    params           print the tunable module parameters
    help             show this message

NOTES:
    Full-speed / performance mode usually requires the DC barrel charger;
    on USB-C the firmware rejects it with EOPNOTSUPP.
";

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() {
        print!("{}", USAGE);
        return ExitCode::FAILURE;
    }

    let result = match args[0].as_str() {
        "get" => cmd_get(),
        "set" => cmd_set(&args[1..]),
        "list" => cmd_list(),
        "status" => cmd_status(),
        "psu" => cmd_psu(),
        "raw" => cmd_raw(&args[1..]),
        "params" => cmd_params(),
        "help" | "-h" | "--help" => {
            print!("{}", USAGE);
            Ok(())
        }
        other => Err(format!("unknown command: {other}\n\n{USAGE}")),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("error: {err}");
            ExitCode::FAILURE
        }
    }
}

fn read_attr(name: &str) -> Result<String, String> {
    let path = attr_path(name);
    fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))
}

fn write_attr(name: &str, value: &str) -> Result<(), String> {
    let path = attr_path(name);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .open(&path)
        .map_err(|e| format!("{path}: {e}"))?;
    file.write_all(value.as_bytes())
        .map_err(|e| format!("{path}: {e}"))
}

/// Locate the directory holding the module's sysfs attributes.
///
/// The module registers a device inside the class, so the attributes live
/// in `/sys/class/redmi_perf/<device>/`.  Rather than hard coding that
/// second level, look for whichever directory actually contains the
/// attribute we want.
fn attr_path(name: &str) -> String {
    let base = std::path::Path::new(SYSFS);
    let direct = base.join(name);
    if direct.exists() {
        return direct.to_string_lossy().into_owned();
    }

    if let Ok(entries) = fs::read_dir(base) {
        for entry in entries.flatten() {
            let candidate = entry.path().join(name);
            if candidate.exists() {
                return candidate.to_string_lossy().into_owned();
            }
        }
    }

    direct.to_string_lossy().into_owned()
}

fn cmd_get() -> Result<(), String> {
    print!("{}", read_attr("mode")?);
    Ok(())
}

fn cmd_set(args: &[String]) -> Result<(), String> {
    let Some(mode) = args.first() else {
        return Err("set needs a mode argument".to_string());
    };

    // Validate locally so we fail fast with a helpful message instead of
    // surfacing an opaque errno from sysfs.
    let known = [
        "unknown", "balanced", "quiet", "turbo", "full-speed", "perf", "bal", "full", "turbo",
        "power-saver",
    ];
    if !known.iter().any(|k| k.eq_ignore_ascii_case(mode))
        && mode.parse::<u8>().is_err()
    {
        return Err(format!(
            "unknown mode: {mode}\navailable: {}",
            read_attr("available_modes").unwrap_or_default()
        ));
    }

    write_attr("mode", mode)?;
    println!("mode set to {mode}");
    Ok(())
}

fn cmd_list() -> Result<(), String> {
    print!("{}", read_attr("available_modes")?);
    Ok(())
}

fn cmd_status() -> Result<(), String> {
    print!("{}", read_attr("status")?);
    Ok(())
}

fn cmd_psu() -> Result<(), String> {
    print!("{}", read_attr("psu")?);
    Ok(())
}

fn cmd_raw(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        print!("{}", read_attr("raw")?);
        return Ok(());
    }

    write_attr("raw", &args[0])?;
    print!("{}", read_attr("raw")?);
    Ok(())
}

fn cmd_params() -> Result<(), String> {
    let mut names: Vec<String> = Vec::new();
    let entries = fs::read_dir(PARAMS).map_err(|e| format!("{PARAMS}: {e}"))?;

    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        names.push(entry.file_name().to_string_lossy().into_owned());
    }
    names.sort();

    for name in names {
        let path = format!("{PARAMS}/{name}");
        let value = fs::read_to_string(&path).unwrap_or_else(|_| "?".to_string());
        println!("{name} = {}", value.trim());
    }
    Ok(())
}
