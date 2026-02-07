import { SpeechLogItem } from "./SpeechLogItem";
import { cn } from "@/lib/utils";
import { motion } from "framer-motion";

interface LogEntry {
  id: string;
  text: string;
  timestamp?: string;
}

interface SpeechLogProps {
  entries: LogEntry[];
  playingId?: string;
  onReplay?: (id: string) => void;
  className?: string;
}

export const SpeechLog = ({ entries, playingId, onReplay, className }: SpeechLogProps) => {
  if (entries.length === 0) {
    return (
      <div className={cn(
        "flex items-center justify-center",
        "h-full min-h-[200px] rounded-xl",
        "bg-background-surface/40 border border-border-subtle border-dashed",
        className
      )}>
        <div className="text-center">
          <p className="font-mono text-xs text-foreground-subtle uppercase tracking-wider mb-1">
            No history yet
          </p>
          <p className="text-xs text-foreground-subtle/60">
            Speak something to see it here
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className={cn("relative", className)}>
      {/* Section header */}
      <div className="flex items-center justify-between mb-3">
        <h3 className="font-mono text-xs font-medium text-foreground-subtle uppercase tracking-wider">
          History
        </h3>
        <span className="font-mono text-[10px] text-foreground-subtle/60 tabular-nums">
          {entries.length} {entries.length === 1 ? 'entry' : 'entries'}
        </span>
      </div>
      
      {/* Scrollable log container */}
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        className={cn(
          "space-y-2 max-h-[360px] overflow-y-auto",
          "pr-1 -mr-1",
          // Custom scrollbar styling
          "[&::-webkit-scrollbar]:w-1",
          "[&::-webkit-scrollbar-track]:bg-transparent",
          "[&::-webkit-scrollbar-thumb]:bg-border",
          "[&::-webkit-scrollbar-thumb]:rounded-full",
          "[&::-webkit-scrollbar-thumb:hover]:bg-foreground-subtle"
        )}
      >
        {entries.map((entry, index) => (
          <SpeechLogItem
            key={entry.id}
            text={entry.text}
            timestamp={entry.timestamp}
            isPlaying={playingId === entry.id}
            onReplay={onReplay ? () => onReplay(entry.id) : undefined}
            index={index}
          />
        ))}
      </motion.div>
      
      {/* Fade overlay at bottom */}
      {entries.length > 3 && (
        <div className="pointer-events-none absolute bottom-0 left-0 right-1 h-12 bg-gradient-to-t from-background to-transparent" />
      )}
    </div>
  );
};
