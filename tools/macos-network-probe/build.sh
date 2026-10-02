#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
probe_dir="$PWD/work/per-app-vpn-probe"
app_dir="$probe_dir/CCSwitchNetworkProbe.app"
extension_dir="$app_dir/Contents/Library/SystemExtensions/com.ccswitch.network-probe.provider.systemextension"
client_dir="$probe_dir/CCSwitchEgressProbe.app"
mkdir -p "$app_dir/Contents/MacOS" "$extension_dir/Contents/MacOS" "$client_dir/Contents/MacOS" "$probe_dir/compiler" "$PWD/work/swift-module-cache"
export TMPDIR="$probe_dir/compiler"
export MACOSX_DEPLOYMENT_TARGET=26.0
case "$(uname -m)" in
    arm64) rust_target="aarch64-apple-darwin" ;;
    x86_64) rust_target="x86_64-apple-darwin" ;;
    *) exit 1 ;;
esac
cargo build --manifest-path crates/app-egress/Cargo.toml --target "$rust_target" --release --offline
swiftc -parse-as-library -module-cache-path "$PWD/work/swift-module-cache" tools/macos-network-probe/Controller.swift tools/macos-network-probe/Upstream.swift tools/macos-network-probe/Policy.swift tools/macos-network-probe/Profile.swift -o "$app_dir/Contents/MacOS/CCSwitchNetworkProbe"
swiftc -parse-as-library -module-cache-path "$PWD/work/swift-module-cache" -import-objc-header tools/macos-network-probe/Bridge.h tools/macos-network-probe/Provider.swift tools/macos-network-probe/Upstream.swift tools/macos-network-probe/Flows.swift tools/macos-network-probe/Filter.swift tools/macos-network-probe/Policy.swift tools/macos-network-probe/ChainGateway.swift "crates/app-egress/target/$rust_target/release/libcc_switch_app_egress.a" -framework Security -framework SystemConfiguration -o "$extension_dir/Contents/MacOS/CCSwitchNetworkProvider"
swiftc -parse-as-library -module-cache-path "$PWD/work/swift-module-cache" tools/macos-network-probe/Client.swift tools/macos-network-probe/Upstream.swift -o "$client_dir/Contents/MacOS/CCSwitchEgressProbe"
cp tools/macos-network-probe/AppInfo.plist "$app_dir/Contents/Info.plist"
cp tools/macos-network-probe/ProviderInfo.plist "$extension_dir/Contents/Info.plist"
cp tools/macos-network-probe/ClientInfo.plist "$client_dir/Contents/Info.plist"
codesign --force --sign - --entitlements tools/macos-network-probe/Provider.entitlements "$extension_dir"
codesign --force --sign - --entitlements tools/macos-network-probe/App.entitlements "$app_dir"
codesign --verify --deep --strict "$app_dir"
codesign --force --sign - "$client_dir"
codesign --verify --strict "$client_dir"
