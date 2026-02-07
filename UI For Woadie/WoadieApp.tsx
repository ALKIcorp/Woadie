import { useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { StatusIndicator } from "./StatusIndicator";
import { ControlButton } from "./ControlButton";
import { VoiceSelect } from "./VoiceSelect";
import { TextInput } from "./TextInput";
import { SpeechLog } from "./SpeechLog";
import { Square, RefreshCw, Mic, Zap } from "lucide-react";
import { cn } from "@/lib/utils";

const MOCK_VOICES = [
  { id: "af_sarah", name: "af_sarah", language: "en-US" },
  { id: "af_bella", name: "af_bella", language: "en-US" },
  { id: "am_adam", name: "am_adam", language: "en-US" },
  { id: "am_michael", name: "am_michael", language: "en-US" },
  { id: "bf_emma", name: "bf_emma", language: "en-GB" },
];

const MOCK_LOG_ENTRIES = [
  {
    id: "1",
    text: "I am Woadie. Your humble usual suspect for stealing champagne glasses from high end restaurants. I am a man of many skills but a master of none. I shine at dark, I move quietly, I am the... Woadie.",
    timestamp: "2:34 PM",
  },
  {
    id: "2",
    text: "I am Woadie. Your humble usual suspect for stealing champagne glasses from high end restaurants. I am a man of many skills but a master of none. I shine at dark, I move quietly, I am the... Woadie.",
    timestamp: "2:33 PM",
  },
  {
    id: "3",
    text: "Move quietly, I am the... Woadie.",
    timestamp: "2:32 PM",
  },
];

export const WoadieApp = () => {
  const [engineStatus, setEngineStatus] = useState<"on" | "off" | "loading">("on");
  const [selectedVoice, setSelectedVoice] = useState("af_sarah");
  const [inputText, setInputText] = useState(
    "I am Woadie. Your humble usual suspect for stealing champagne glasses from high end restaurants. I am a man of many skills but a master of none. I shine at dark, I move quietly, I am the... Woadie."
  );
  const [genTime, setGenTime] = useState(1586);
  const [playingId, setPlayingId] = useState<string | undefined>();
  const [logEntries, setLogEntries] = useState(MOCK_LOG_ENTRIES);

  const handleToggleEngine = () => {
    if (engineStatus === "on") {
      setEngineStatus("off");
    } else {
      setEngineStatus("loading");
      setTimeout(() => setEngineStatus("on"), 1500);
    }
  };

  const handleSpeak = () => {
    if (!inputText.trim()) return;
    
    const newEntry = {
      id: Date.now().toString(),
      text: inputText,
      timestamp: new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }),
    };
    
    setLogEntries(prev => [newEntry, ...prev]);
    setPlayingId(newEntry.id);
    setGenTime(Math.floor(Math.random() * 1000) + 800);
    
    // Simulate playback ending
    setTimeout(() => setPlayingId(undefined), 3000);
  };

  const handleReplay = (id: string) => {
    setPlayingId(id);
    setTimeout(() => setPlayingId(undefined), 3000);
  };

  return (
    <div className="min-h-screen bg-background noise">
      {/* Subtle ambient gradient */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[800px] h-[600px] bg-primary/[0.02] blur-[120px] rounded-full" />
      </div>

      <div className="relative z-10 mx-auto max-w-2xl px-6 py-8">
        {/* Header */}
        <motion.header
          initial={{ opacity: 0, y: -12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.4 }}
          className="flex items-center justify-between mb-8"
        >
          {/* Logo & Status */}
          <div className="flex items-center gap-4">
            <div className="flex items-center gap-3">
              <div className="relative">
                <Zap className="h-5 w-5 text-primary" />
                <div className="absolute inset-0 blur-md bg-primary/30" />
              </div>
              <h1 className="font-mono text-lg font-semibold tracking-tight">
                Woadie
              </h1>
            </div>
            
            <div className="h-4 w-px bg-border" />
            
            <StatusIndicator
              status={engineStatus}
              label={engineStatus === "loading" ? "Starting..." : engineStatus === "on" ? "Engine ON" : "Engine OFF"}
            />
          </div>

          {/* Gen time */}
          <div className="font-mono text-xs text-foreground-subtle tabular-nums">
            <span className="text-foreground-subtle/60">Gen:</span>{" "}
            <span className="text-foreground-muted">{genTime} ms</span>
          </div>
        </motion.header>

        {/* Controls Bar */}
        <motion.div
          initial={{ opacity: 0, y: -8 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.4, delay: 0.1 }}
          className={cn(
            "flex items-center justify-center gap-3 flex-wrap",
            "p-3 mb-6 rounded-xl",
            "bg-background-surface/50 border border-border-subtle"
          )}
        >
          <ControlButton
            onClick={handleToggleEngine}
            icon={<Square className="h-3.5 w-3.5" />}
            disabled={engineStatus === "loading"}
          >
            {engineStatus === "on" ? "Stop Engine" : "Start Engine"}
          </ControlButton>

          <ControlButton
            icon={<RefreshCw className="h-3.5 w-3.5" />}
            disabled={engineStatus !== "on"}
          >
            Refresh Voices
          </ControlButton>

          <div className="h-5 w-px bg-border hidden sm:block" />

          <VoiceSelect
            voices={MOCK_VOICES}
            selectedVoice={selectedVoice}
            onVoiceChange={setSelectedVoice}
          />
        </motion.div>

        {/* Input Section */}
        <motion.div
          initial={{ opacity: 0, y: -8 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.4, delay: 0.15 }}
          className="mb-6"
        >
          <div className="flex gap-3">
            <div className="flex-1">
              <TextInput
                value={inputText}
                onChange={(e) => setInputText(e.target.value)}
                placeholder="Enter text to speak..."
                disabled={engineStatus !== "on"}
              />
            </div>
            
            <ControlButton
              variant="primary"
              onClick={handleSpeak}
              disabled={engineStatus !== "on" || !inputText.trim()}
              icon={<Mic className="h-4 w-4" />}
              className="self-start"
            >
              Speak
            </ControlButton>
          </div>
        </motion.div>

        {/* Speech Log */}
        <motion.div
          initial={{ opacity: 0, y: -8 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.4, delay: 0.2 }}
        >
          <SpeechLog
            entries={logEntries}
            playingId={playingId}
            onReplay={handleReplay}
          />
        </motion.div>

        {/* Footer hint */}
        <motion.footer
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ duration: 0.5, delay: 0.4 }}
          className="mt-12 text-center"
        >
          <p className="font-mono text-[10px] text-foreground-subtle/40 uppercase tracking-widest">
            ⌘ + Enter to speak • Built with elegance
          </p>
        </motion.footer>
      </div>
    </div>
  );
};
