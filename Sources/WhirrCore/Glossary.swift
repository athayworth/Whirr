import Foundation

/// Plain-English explanations behind every ⓘ in Whirr and the Learn
/// section. Numbers here are the same ones the findings use, so what
/// Whirr teaches and what it reports never drift apart (GlossaryTests).
public enum Glossary {
    public enum Group: String, CaseIterable, Sendable {
        case wifi, connection, mac

        public var title: String {
            switch self {
            case .wifi: return "Wi-Fi"
            case .connection: return "Your connection"
            case .mac: return "Your Mac"
            }
        }

        public var terms: [Term] {
            switch self {
            case .wifi: return [.signalStrength, .snr, .band, .channel, .channelWidth, .radarChannels, .autoChannel, .crowding, .linkRate]
            case .connection: return [.routerHop, .internetHop, .delay, .stall, .lost, .speed, .underLoad, .outage]
            case .mac: return [.memoryPressure, .swap, .cpu, .workload, .heat, .diskSpace]
            }
        }
    }

    public enum Term: String, CaseIterable, Identifiable, Sendable {
        case signalStrength, snr, band, channel, channelWidth, radarChannels, autoChannel, crowding, linkRate
        case routerHop, internetHop, delay, stall, lost, speed, underLoad, outage
        case memoryPressure, swap, cpu, workload, heat, diskSpace

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .signalStrength: return "Signal strength (dBm)"
            case .snr: return "Signal above noise"
            case .band: return "2.4 GHz, 5 GHz and 6 GHz"
            case .channel: return "Channel"
            case .channelWidth: return "Channel width (MHz)"
            case .radarChannels: return "Radar-shared channels"
            case .autoChannel: return "Automatic channel selection"
            case .crowding: return "Wi-Fi crowding"
            case .linkRate: return "Link rate"
            case .routerHop: return "Your Mac → your router"
            case .internetHop: return "Your Mac → the internet"
            case .delay: return "Delay (ms)"
            case .stall: return "Stall"
            case .lost: return "Lost checks"
            case .speed: return "Speed (Mbps)"
            case .underLoad: return "Delay under load"
            case .outage: return "Outage"
            case .memoryPressure: return "Memory pressure"
            case .swap: return "Swap"
            case .cpu: return "CPU %"
            case .workload: return "Workload"
            case .heat: return "Heat"
            case .diskSpace: return "Free disk space"
            }
        }

        /// One or two sentences: the hover tooltip and the popover's lead.
        public var short: String {
            switch self {
            case .signalStrength:
                return "How strongly your Mac hears the router. Closer to zero is stronger: −50 is excellent, −70 is getting weak."
            case .snr:
                return "How far the router's signal stands out above background radio hiss. Above 25 dB is comfortable; below \(ConnectionRuleConfig().weakSnr) dB it can get unreliable."
            case .band:
                return "Separate sets of airwaves Wi-Fi can use. 5 GHz is faster and less crowded than 2.4 GHz; 2.4 GHz reaches farther through walls."
            case .channel:
                return "Which slice of the airwaves your router talks on. Networks sharing a slice take turns."
            case .channelWidth:
                return "How wide a stretch of airwaves your network uses. At 80 MHz, one network covers four channel numbers at once."
            case .radarChannels:
                return "5 GHz channels 52–144 are shared with weather and airport radar, which is why they're often empty."
            case .autoChannel:
                return "Many routers choose their channel on their own, often when they restart. Providers may call it Smart WiFi."
            case .crowding:
                return "How many Wi-Fi networks Whirr heard sharing your stretch of airwaves during a connection test."
            case .linkRate:
                return "The speed your Mac and router agreed to talk at over Wi-Fi. It's a ceiling, not what you actually get."
            case .routerHop:
                return "Checks that only travel inside your home, to the router and back. Trouble here is inside your home."
            case .internetHop:
                return "Checks that travel all the way out to the internet (1.1.1.1 and 8.8.8.8) and back."
            case .delay:
                return "How long a message takes to get there and back, in thousandths of a second. Lower is better."
            case .stall:
                return "A check that took far longer than usual, or never came back. Stalls are what make games and calls stutter."
            case .lost:
                return "The share of checks that got no reply within a second."
            case .speed:
                return "How much data per second your connection carries, in megabits per second. Download is what you receive; upload is what you send."
            case .underLoad:
                return "How much the delay rises while the connection is busy — for example during a download or a backup."
            case .outage:
                return "At least \(Int(OutageDetector.minDuration)) seconds in a row when nothing on the internet answered."
            case .memoryPressure:
                return "macOS's own judgment of how hard it's working to find memory for your apps — the same reading Activity Monitor shows."
            case .swap:
                return "Memory macOS has moved to disk to make room. It only slows things down while macOS keeps reading it back."
            case .cpu:
                return "How much processor time something is using. 100% is one full core, and your Mac has several."
            case .workload:
                return "How many tasks are waiting for the processor, compared with how many cores your Mac has."
            case .heat:
                return "Whether macOS is slowing the processor down to cool off."
            case .diskSpace:
                return "Room left on your startup disk, including space macOS can clear on its own when it needs to."
            }
        }

        /// The fuller explanation in the popover and the Learn section.
        public var detail: String {
            switch self {
            case .signalStrength:
                return "Measured in dBm, always a negative number. Every 3 dB is roughly double or half the power, so −60 is a lot stronger than −70. Distance, walls, floors and closets all weaken it. Whirr calls the signal weak below \(ConnectionRuleConfig().weakRssi) dBm."
            case .snr:
                return "Think of talking in a noisy room: what matters isn't only how loud someone is, but how much louder than the background. Your Mac measures both the signal and the noise; the gap between them, in dB, is the signal-to-noise ratio (SNR)."
            case .band:
                return "Many routers broadcast 2.4 GHz and 5 GHz under one network name and let each device choose. 6 GHz (Wi-Fi 6E and 7) is newer and even less crowded, but reaches less far."
            case .channel:
                return "Like lanes on a highway, a channel number marks a position on the airwaves. On their own the numbers don't tell you much: what matters is whether neighbors use the same stretch, which depends on channel width too."
            case .channelWidth:
                return "Wider is faster, like more lanes, but your network then shares airtime with anyone on any part of that stretch. That's why a network on channel 40 at 80 MHz shares the airwaves of channels 36–48."
            case .radarChannels:
                return "Routers on these channels must listen for radar and move away if they hear it, which drops Wi-Fi for a minute or more while they switch. Away from airports and weather stations that's rare, which makes these channels a quiet option if your router offers them."
            case .autoChannel:
                return "Automatic selection can be helpful, but it can also move your network onto a busy stretch after a restart. Whirr logs every channel change it sees and compares how each stretch has done, so you can judge with evidence."
            case .crowding:
                return "Only networks heard at \(ConnectionReportCard.loudRssi) dBm or stronger make your router wait its turn; fainter ones barely matter. Without Location permission macOS doesn't tell Whirr network names, so it can't tell which network is yours — and one router can broadcast several. A crowded stretch only matters if your Wi-Fi is actually having trouble."
            case .linkRate:
                return "It changes constantly with signal strength and interference. Real-world speed is usually about half of it, or less."
            case .routerHop:
                return "Whirr checks the router every 2 seconds. That trip never leaves your home, so stalls here point to Wi-Fi, this Mac, or the router itself — not your internet provider."
            case .internetHop:
                return "This trip includes the router leg. If the router leg is steady but this one stalls, the delay is beyond your router: the line, your provider, or heavy traffic from your own home filling the line. The internet only counts as down when both public hosts stop answering."
            case .delay:
                return "Also called latency or ping. Under about 30 ms to the internet is good for games. Sudden jumps hurt more than a steady, slightly higher number."
            case .stall:
                return "Whirr counts a stall when a reply takes more than three times the typical delay and at least 50 ms longer, or doesn't come back at all. Your speed can be excellent and you can still have stalls."
            case .lost:
                return "A little loss now and then is normal. Steady loss above 1–2% makes connections stutter and drop."
            case .speed:
                return "Game and video streaming generally need about 25–45 Mbps of download. Speed alone doesn't make a connection smooth: delay and stalls matter just as much for games and calls."
            case .underLoad:
                return "When something fills the connection, messages can queue up behind it. A big rise (sometimes called bufferbloat) makes games lag the moment anything else uses the internet. The connection test measures where the rise happens: inside your home, or beyond the router."
            case .outage:
                return "Whirr records which side failed when its checks show it clearly: the router, the line beyond the router, or this Mac's Wi-Fi. When the evidence is mixed, or the router doesn't answer checks, it records \"connection down\" rather than guessing."
            case .memoryPressure:
                return "macOS fills spare memory with caches on purpose, so \"little free memory\" is normal and not a problem. Pressure rises when macOS has to compress memory or move it to disk to keep up — that's when apps start to slow down."
            case .swap:
                return "Swap that just sits there costs nothing, and it may stay until you restart. When macOS has to keep reading it back while memory is under pressure, everything slows — Whirr calls that actively paging."
            case .cpu:
                return "So one app can show more than 100%. A process stuck high for a long time when you aren't asking it to do anything may be stuck."
            case .workload:
                return "Light means there's room to spare. Busy means the cores are mostly in use. Overloaded means tasks are queueing for the processor, so things feel slow."
            case .heat:
                return "Macs reduce speed when they get hot, to protect themselves. Heavy work, blocked vents and soft surfaces all add heat."
            case .diskSpace:
                return "macOS needs free space for swap, updates and caches. Whirr starts flagging it below \(Int(LowDiskSpaceRuleConfig().warningFreeGB)) GB free, and treats it as serious below \(Int(LowDiskSpaceRuleConfig().criticalFreeGB)) GB, when updates can fail."
            }
        }
    }
}
