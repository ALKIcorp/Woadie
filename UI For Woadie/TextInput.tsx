import { cn } from "@/lib/utils";
import { motion } from "framer-motion";
import { forwardRef } from "react";

interface TextInputProps {
  value?: string;
  onChange?: (e: React.ChangeEvent<HTMLTextAreaElement>) => void;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
}

export const TextInput = forwardRef<HTMLTextAreaElement, TextInputProps>(
  ({ className, value, onChange, placeholder, disabled }, ref) => {
    return (
      <div className="relative">
        <motion.textarea
          ref={ref}
          initial={{ opacity: 0, y: 4 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.3 }}
          value={value}
          onChange={onChange}
          placeholder={placeholder}
          disabled={disabled}
          className={cn(
            "w-full resize-none",
            "min-h-[52px] py-3 px-4 rounded-xl",
            "bg-background-surface border border-border-subtle",
            "font-mono text-sm text-foreground leading-relaxed",
            "placeholder:text-foreground-subtle",
            "transition-all duration-200",
            "hover:border-border",
            "focus:outline-none focus:ring-2 focus:ring-primary/30 focus:border-primary/50",
            "scrollbar-thin scrollbar-thumb-border scrollbar-track-transparent",
            className
          )}
          rows={1}
        />
        
        {/* Subtle gradient overlay at edges */}
        <div className="pointer-events-none absolute inset-x-0 top-0 h-3 rounded-t-xl bg-gradient-to-b from-background-surface/50 to-transparent opacity-0" />
      </div>
    );
  }
);

TextInput.displayName = "TextInput";
