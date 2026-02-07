import { motion } from "framer-motion";
import { cn } from "@/lib/utils";
import { Volume2, Copy, Check } from "lucide-react";
import { useState } from "react";

interface SpeechLogItemProps {
  text: string;
  timestamp?: string;
  isPlaying?: boolean;
  onReplay?: () => void;
  index: number;
}

export const SpeechLogItem = ({ text, timestamp, isPlaying, onReplay, index }: SpeechLogItemProps) => {
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    await navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <motion.div
      initial={{ opacity: 0, x: -8 }}
      animate={{ opacity: 1, x: 0 }}
      transition={{ duration: 0.25, delay: index * 0.05 }}
      className={cn(
        "group relative",
        "p-4 rounded-xl",
        "bg-background-surface/60 border border-border-subtle",
        "transition-all duration-200",
        "hover:bg-background-surface hover:border-border",
        isPlaying && "border-primary/40 bg-primary/5"
      )}
    >
      {/* Playing indicator */}
      {isPlaying && (
        <motion.div
          className="absolute left-0 top-0 bottom-0 w-0.5 rounded-l-xl bg-primary"
          layoutId="playing-indicator"
        />
      )}
      
      {/* Content */}
      <p className="font-mono text-sm text-foreground leading-relaxed pr-16">
        {text}
      </p>
      
      {/* Timestamp */}
      {timestamp && (
        <span className="block mt-2 font-mono text-[10px] text-foreground-subtle uppercase tracking-wider">
          {timestamp}
        </span>
      )}
      
      {/* Actions */}
      <div className="absolute right-3 top-3 flex items-center gap-1.5 opacity-0 group-hover:opacity-100 transition-opacity">
        <button
          onClick={handleCopy}
          className={cn(
            "p-1.5 rounded-md",
            "text-foreground-subtle hover:text-foreground",
            "hover:bg-background-glass",
            "transition-all duration-150"
          )}
        >
          {copied ? (
            <Check className="h-3.5 w-3.5 text-success" />
          ) : (
            <Copy className="h-3.5 w-3.5" />
          )}
        </button>
        
        {onReplay && (
          <button
            onClick={onReplay}
            className={cn(
              "p-1.5 rounded-md",
              "text-foreground-subtle hover:text-primary",
              "hover:bg-primary/10",
              "transition-all duration-150"
            )}
          >
            <Volume2 className="h-3.5 w-3.5" />
          </button>
        )}
      </div>
    </motion.div>
  );
};
