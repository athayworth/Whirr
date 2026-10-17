import SwiftUI
import WhirrCore

/// Plain-English instructions for fixes Whirr can't do itself.
struct HowToSheet: View {
    let howTo: SuggestedAction.HowTo
    let gatewayIP: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let content = HowToContent.for(howTo, gatewayIP: gatewayIP)
        VStack(alignment: .leading, spacing: 16) {
            Text(content.title).font(.title2.weight(.semibold))
            if let intro = content.intro {
                Text(intro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(content.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.quaternary))
                        Text(step).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            if let note = content.note {
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct HowToContent {
    let title: String
    let intro: String?
    let steps: [String]
    let note: String?

    static func `for`(_ howTo: SuggestedAction.HowTo, gatewayIP: String?) -> HowToContent {
        let router = gatewayIP.map { "http://\($0)" } ?? "your router's address (often http://192.168.1.1)"
        switch howTo {
        case .changeWiFiChannel:
            return HowToContent(
                title: "Change your router's Wi-Fi channel",
                intro: "Wi-Fi networks on the same stretch of airwaves take turns talking. If the connection test showed your Wi-Fi having trouble and your stretch is crowded, moving to a quieter one can help.",
                steps: [
                    "Open your internet provider's app or website (for example the Optimum app, or optimum.net → My network) and find the router or Wi-Fi settings. Or, on a device on your home Wi-Fi, visit \(router) in a web browser.",
                    "Find the 5 GHz channel setting — often under Wi-Fi, Wireless, or Advanced. Automatic mode may be called \"Select best channel automatically\" or Smart WiFi.",
                    "Choose a channel the connection test listed as quiet. Go by stretch, not just number: at 80 MHz, channel 40 shares the airwaves of channels 36–48.",
                    "Save. Devices reconnect on their own within a minute."
                ],
                note: "Automatic modes can change channel on their own, especially after a restart. Whirr logs every change it sees (Connection → Channel changes) and compares how each stretch has done over several evenings, so you can tell whether a manual choice is actually better."
            )
        case .talkToISP:
            return HowToContent(
                title: "Stalls beyond your router: what to check",
                intro: "Your Mac's link to the router was clean, but the connection beyond it stalled. That can come from your own network being busy, from the router or modem, or from your provider.",
                steps: [
                    "Check whether anything is uploading or downloading heavily — backups (Time Machine, Backblaze), cloud sync, game updates, or someone else streaming. If the stalls stop when those pause, that was the cause.",
                    "If they keep happening while nothing else is busy, restart the router once: unplug it for 30 seconds and give it three minutes to come back.",
                    "If they still continue, contact your provider: \"The connection beyond my router keeps stalling, even when nothing else is using it.\" Give them dates and times — in Whirr, Connection → Outages → Copy summary for your provider.",
                    "Ask them to check the signal levels on your line and whether your gateway needs replacing."
                ],
                note: nil
            )
        case .improveSignal:
            return HowToContent(
                title: "Ways to improve your Wi-Fi signal",
                intro: "A weak signal, or one buried in background noise, makes everything slower and spikier.",
                steps: [
                    "If the router is in a closet, keep the door open while you need a good connection, and raise the router off the floor onto a shelf.",
                    "Keep it away from metal, mirrors, fish tanks and microwaves.",
                    "If the router can't move, a mesh Wi-Fi point or extender placed halfway between it and you usually fixes weak signal.",
                    "Use the 5 GHz network when you're reasonably close to the router; 2.4 GHz reaches farther but is slower and more crowded."
                ],
                note: nil
            )
        case .freeDiskSpace:
            return HowToContent(
                title: "Free up disk space",
                intro: "macOS slows down as the startup disk fills up.",
                steps: [
                    "Open System Settings → General → Storage to see what's using space and macOS's own suggestions.",
                    "Empty the Trash and clear old Downloads.",
                    "Move large files (videos, old projects, disk images) to an external drive or cloud storage."
                ],
                note: nil
            )
        case .reinstallSampler:
            return HowToContent(
                title: "Update Whirr's background helper",
                intro: "Whirr's optional background helper (which lets it see system processes) is older than the app and writes data the app can't read.",
                steps: [
                    "Open Terminal in Whirr's project folder.",
                    "Run: sudo scripts/install-sampler.sh",
                    "Enter your Mac password when asked. Whirr picks the new helper up within a few seconds."
                ],
                note: nil
            )
        case .routerOutage:
            return HowToContent(
                title: "Your router stopped responding",
                intro: nil,
                steps: [
                    "Unplug the router's power for 30 seconds, then plug it back in.",
                    "Wait two to three minutes for it to come back fully.",
                    "If this keeps happening, check Connection → Outages. A router that hangs often may be failing — providers usually replace their own equipment for free."
                ],
                note: "After a restart, routers on automatic channel selection may pick a different Wi-Fi channel."
            )
        case .connectionDown:
            return HowToContent(
                title: "Your connection is down",
                intro: "Nothing beyond your Mac is answering. Whirr can't tell yet whether the router or the internet line is at fault, because your router hasn't answered its checks.",
                steps: [
                    "Check whether other devices at home are also offline. If only this Mac is, turn Wi-Fi off and on.",
                    "Check your provider's app or website for a reported outage in your area.",
                    "If there's no reported outage, unplug the router for 30 seconds, plug it back in, and wait two to three minutes."
                ],
                note: "Whirr logs when this starts and ends, in Connection → Outages."
            )
        case .wifiDropped:
            return HowToContent(
                title: "Your Wi-Fi disconnected",
                intro: "This Mac lost its Wi-Fi connection. From here, Whirr can't tell whether the router stopped broadcasting or only this Mac dropped off.",
                steps: [
                    "Check whether other devices at home are still online. If they are, the problem is on this Mac: turn Wi-Fi off and on from the menu bar.",
                    "If everything is offline, the router may be restarting. Give it two to three minutes, then restart it if it doesn't come back."
                ],
                note: "Whirr logs when this starts and ends, in Connection → Outages."
            )
        case .ispOutage:
            return HowToContent(
                title: "Your internet line is down",
                intro: "Your router is working, but nothing beyond it is reachable.",
                steps: [
                    "Check your provider's app or website for a reported outage in your area.",
                    "Restarting the router rarely fixes a line outage, but it's harmless to try.",
                    "Whirr is logging when this starts and ends. If it happens often, use Copy summary for your provider in Connection → Outages."
                ],
                note: nil
            )
        }
    }
}
