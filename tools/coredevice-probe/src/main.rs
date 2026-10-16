//! Read-only capability check. No pairing, developer-image mounting, capture,
//! HID, media-start or stop-all operations are exposed by this program.
use std::{net::IpAddr, time::Duration};

use idevice::{
    IdeviceService, RsdService,
    core_device::DisplayServiceClient,
    core_device_proxy::CoreDeviceProxy,
    lockdown::LockdownClient,
    provider::RsdProvider,
    rsd::RsdHandshake,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdDevice},
};
use serde_json::{Value, json};

type ProbeResult<T> = Result<T, Box<dyn std::error::Error>>;
const DISPLAY: &str = "com.apple.coredevice.displayservice";

fn failure_category(error: &(dyn std::error::Error + 'static)) -> String {
    use idevice::IdeviceError;
    match error.downcast_ref::<IdeviceError>() {
        Some(IdeviceError::Socket(io)) => {
            format!("socket {:?}, OS error {:?}", io.kind(), io.raw_os_error())
        }
        Some(IdeviceError::InvalidHostID) => "existing host pairing unavailable".into(),
        Some(IdeviceError::DeviceLocked) => "device locked".into(),
        Some(IdeviceError::ServiceNotFound) => "requested service unavailable".into(),
        Some(IdeviceError::DeveloperModeNotEnabled) => "target Developer Mode disabled".into(),
        Some(IdeviceError::ImageNotMounted) => "target developer image unavailable".into(),
        Some(IdeviceError::DeviceNotFound) => "USB device unavailable".into(),
        _ => "protocol or request failure (response omitted)".into(),
    }
}

#[derive(Debug, PartialEq)]
enum Command {
    List,
    Usb(usize),
    Rsd(IpAddr, u16),
}

fn command(args: &[String]) -> ProbeResult<Command> {
    match args {
        [] => Ok(Command::List),
        [a] if a == "--list" => Ok(Command::List),
        [a, n] if a == "--usb" => Ok(Command::Usb(n.parse()?)),
        [a, host, port] if a == "--rsd" => {
            let ip: IpAddr = host.parse()?;
            let port: u16 = port.parse()?;
            if port == 0 || ip.is_unspecified() || ip.is_multicast() {
                return Err(
                    "A specific existing device tunnel address and nonzero port are required"
                        .into(),
                );
            }
            Ok(Command::Rsd(ip, port))
        }
        _ => Err("Usage: audiomix-coredevice-probe [--list | --usb INDEX | --rsd IP PORT]".into()),
    }
}

async fn usb_devices() -> ProbeResult<Vec<UsbmuxdDevice>> {
    // Use the local Apple daemon only; do not inherit a remote socket override.
    let address = UsbmuxdAddr::UnixSocket(UsbmuxdAddr::SOCKET_FILE.into());
    let mut connection = address.connect(1).await?;
    let mut devices: Vec<_> = connection
        .get_devices()
        .await?
        .into_iter()
        .filter(|d| d.connection_type == Connection::Usb)
        .collect();
    devices.sort_by(|a, b| a.udid.cmp(&b.udid));
    Ok(devices)
}

// Preserve numeric/Boolean capabilities while omitting identity strings/data.
fn describe(value: &plist::Value, depth: usize) -> Value {
    if depth > 8 {
        return json!("depth limit");
    }
    match value {
        plist::Value::Boolean(v) => json!(v),
        plist::Value::Integer(v) => v
            .as_signed()
            .map_or_else(|| json!(v.as_unsigned()), |n| json!(n)),
        plist::Value::Real(v) => json!(v),
        plist::Value::Array(a) => {
            Value::Array(a.iter().take(64).map(|v| describe(v, depth + 1)).collect())
        }
        plist::Value::Dictionary(d) => Value::Object(
            d.iter()
                .take(128)
                .map(|(k, v)| (k.clone(), describe(v, depth + 1)))
                .collect(),
        ),
        plist::Value::String(_) => json!("string omitted"),
        plist::Value::Data(d) => json!({"data_bytes": d.len()}),
        _ => json!("other value omitted"),
    }
}

async fn inspect(provider: &mut impl RsdProvider, mut rsd: RsdHandshake) -> ProbeResult<Value> {
    let mut services: Vec<_> = rsd
        .services
        .keys()
        .filter(|name| {
            name.contains("displayservice")
                || name.contains("screenshot")
                || name.contains("image_mounter")
        })
        .cloned()
        .collect();
    services.sort();
    let mut report = json!({
        "rsd_protocol": rsd.protocol_version,
        "service_count": rsd.services.len(),
        "relevant_services": services,
        "display_service_advertised": rsd.services.contains_key(DISPLAY),
        "media_started": false,
        "audio_reception_verified": false
    });
    if !rsd.services.contains_key(DISPLAY) {
        report["next_step"] = json!(
            "No display service advertised. Check target OS and existing developer-service readiness; the probe changes neither."
        );
        return Ok(report);
    }
    let mut display = DisplayServiceClient::connect_rsd(provider, &mut rsd).await?;
    report["media_support"] = describe(&display.get_media_support_info().await?, 0);
    Ok(report)
}

async fn run(cmd: Command) -> ProbeResult<Value> {
    match cmd {
        Command::List => {
            let devices = usb_devices().await?;
            Ok(
                json!({"usb_device_count": devices.len(), "usb_indices": (0..devices.len()).collect::<Vec<_>>(),
                "media_started": false,
                "note": "Indices are for this inventory. --usb INDEX reads capabilities only; no pairing or capture."}),
            )
        }
        Command::Usb(index) => {
            let devices = usb_devices().await?;
            let device = devices
                .get(index)
                .ok_or("USB device index is unavailable; reconnect/unlock/trust and list again")?;
            let provider = device.to_provider(
                UsbmuxdAddr::UnixSocket(UsbmuxdAddr::SOCKET_FILE.into()),
                "AudioMix capability probe",
            );
            let mut lockdown = LockdownClient::connect(&provider).await?;
            let version = lockdown.get_value(Some("ProductVersion"), None).await?;
            let query = tokio::time::timeout(Duration::from_secs(10), async {
                // Existing host pairing is required by CoreDeviceProxy::connect.
                let proxy = CoreDeviceProxy::connect(&provider).await?;
                let port = proxy.tunnel_info().server_rsd_port;
                let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
                let stream = adapter.connect(port).await?;
                let rsd = RsdHandshake::new(stream).await?;
                inspect(&mut adapter, rsd).await
            })
            .await;
            let mut result = match query {
                Ok(Ok(report)) => report,
                Ok(Err(error)) => json!({"capability_query_error":failure_category(&*error),
                    "media_started":false,"audio_reception_verified":false}),
                Err(_) => json!({"capability_query_error":"developer-service query timed out",
                    "media_started":false,"audio_reception_verified":false}),
            };
            result["target_os"] = json!(version.as_string());
            Ok(result)
        }
        Command::Rsd(mut host, port) => {
            // Caller supplies an already-established, trusted development tunnel.
            // No port scan, new pairing or system network interface is created.
            let stream = tokio::net::TcpStream::connect((host, port)).await?;
            let rsd = RsdHandshake::new(stream).await?;
            inspect(&mut host, rsd).await
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let cmd = match command(&args) {
        Ok(cmd) => cmd,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let report = match tokio::time::timeout(Duration::from_secs(15), run(cmd)).await {
        Ok(Ok(report)) => report,
        // Avoid echoing a protocol response that might contain device identity.
        Ok(Err(e)) => {
            eprintln!(
                "Capability probe failed: {}. Check USB trust, existing pairing, target developer readiness, or the supplied tunnel endpoint. No media was started.",
                failure_category(&*e)
            );
            std::process::exit(1);
        }
        Err(_) => {
            eprintln!("Capability probe timed out after 15 seconds. No media was started.");
            std::process::exit(1);
        }
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&report).expect("JSON report")
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }
    #[test]
    fn explicit_read_only_commands() {
        assert_eq!(command(&[]).unwrap(), Command::List);
        assert_eq!(command(&args(&["--usb", "0"])).unwrap(), Command::Usb(0));
        for invalid in [
            vec!["--pair"],
            vec!["--start"],
            vec!["--usb", "-1"],
            vec!["--rsd", "::", "123"],
            vec!["--rsd", "ff02::1", "123"],
            vec!["--rsd", "::1", "0"],
            vec!["--rsd", "example.com", "1"],
        ] {
            assert!(command(&args(&invalid)).is_err());
        }
    }
    #[test]
    fn capability_report_omits_strings_and_bytes() {
        let mut values = plist::Dictionary::new();
        values.insert(
            "identity".into(),
            plist::Value::String("SYNTHETIC_SECRET".into()),
        );
        values.insert("audio".into(), plist::Value::Boolean(true));
        values.insert("bytes".into(), plist::Value::Data(vec![1, 2, 3]));
        let report = describe(&plist::Value::Dictionary(values), 0);
        assert!(!report.to_string().contains("SYNTHETIC_SECRET"));
        assert_eq!(report["audio"], true);
        assert_eq!(report["bytes"]["data_bytes"], 3);
    }
    #[test]
    fn failures_preserve_useful_categories_without_response_contents() {
        let denied = idevice::IdeviceError::Socket(std::io::Error::from_raw_os_error(1));
        assert!(failure_category(&denied).contains("PermissionDenied"));
        let response = idevice::IdeviceError::UnexpectedResponse("SYNTHETIC_SECRET".into());
        assert!(!failure_category(&response).contains("SYNTHETIC_SECRET"));
    }
}
