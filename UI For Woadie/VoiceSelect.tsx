import { cn } from "@/lib/utils";
import { ChevronDown } from "lucide-react";
import { motion } from "framer-motion";

interface Voice {
  id: string;
  name: string;
  language?: string;
}

interface VoiceSelectProps {
  voices: Voice[];
  selectedVoice: string;
  onVoiceChange: (voiceId: string) => void;
  className?: string;
}

export const VoiceSelect = ({ voices, selectedVoice, onVoiceChange, className }: VoiceSelectProps) => {
  const selected = voices.find(v => v.id === selectedVoice);
  
  return (
    <div className={cn("flex items-center gap-3", className)}>
      <label className="font-mono text-xs font-medium text-foreground-subtle uppercase tracking-wider">
        Voice
      </label>
      
      <div className="relative">
        <motion.select
          whileHover={{ borderColor: "hsl(var(--border))" }}
          value={selectedVoice}
          onChange={(e) => onVoiceChange(e.target.value)}
          className={cn(
            "appearance-none cursor-pointer",
            "h-9 pl-3 pr-9 rounded-lg",
            "bg-background-surface border border-border-subtle",
            "font-mono text-sm text-foreground",
            "transition-all duration-200",
            "hover:border-border hover:bg-background-glass",
            "focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary/50"
          )}
        >
          {voices.map((voice) => (
            <option key={voice.id} value={voice.id}>
              {voice.name} {voice.language && `(${voice.language})`}
            </option>
          ))}
        </motion.select>
        
        <ChevronDown className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2 h-4 w-4 text-foreground-subtle" />
      </div>
    </div>
  );
};
