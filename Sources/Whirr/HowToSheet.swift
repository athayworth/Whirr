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
                intro: "Neighbors' Wi-Fi on the same channel takes turns with yours. Moving to a quieter channel is free and takes five minutes.",
                steps: [
                    "Open your internet provider's app (for example the Optimum app) and find the router or Wi-Fi settings. Or, on a device on your home Wi-Fi, visit \(router) in a web browser.",
                    "Find the 5 GHz Wi-Fi settings — often under Wi-Fi, Wireless, or Advanced.",
                    "Change Channel from Automatic to a specific channel. Run Connection → Check my connection to see which channel is least crowded.",
                    "Save. Devices reconnect on their own within a minute."
                ],
                note: "Routers set to Automatic pick a new channel every time they restart, so unplugging the router can move you onto a crowded channel. Setting it manually keeps it. Whirr remembers which channel you were on, so after a few evenings the Connection section shows how each one performed."
            )
        case .talkToISP:
            return HowToContent(
                title: "What to tell your internet provider",
                intro: "Whirr found that your Wi-Fi to the router is fine, but the connection beyond it isn't. That's the provider's side.",
                steps: [
                    "Contact your provider and say: \"My home Wi-Fi is fine, but the connection beyond my router keeps stalling and dropping.\"",
                    "Give them dates and times. In Whirr, open Connection and use Copy summary for your provider under Outages.",
                    "Ask them to check the signal levels on your line and whether your modem or gateway needs replacing — replacements are usually free."
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
