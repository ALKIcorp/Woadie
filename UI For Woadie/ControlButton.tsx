import { motion } from "framer-motion";
import { cn } from "@/lib/utils";
import { forwardRef } from "react";

interface ControlButtonProps {
  variant?: "default" | "primary" | "ghost";
  size?: "sm" | "md";
  icon?: React.ReactNode;
  className?: string;
  children?: React.ReactNode;
  onClick?: () => void;
  disabled?: boolean;
}

export const ControlButton = forwardRef<HTMLButtonElement, ControlButtonProps>(
  ({ className, variant = "default", size = "md", icon, children, onClick, disabled }, ref) => {
    return (
      <motion.button
        ref={ref}
        whileHover={disabled ? {} : { scale: 1.02 }}
        whileTap={disabled ? {} : { scale: 0.98 }}
        onClick={onClick}
        disabled={disabled}
        className={cn(
          "inline-flex items-center justify-center gap-2 font-mono text-xs font-medium tracking-wide",
          "rounded-lg border transition-all duration-200",
          "focus:outline-none focus:ring-2 focus:ring-primary/40 focus:ring-offset-2 focus:ring-offset-background",
          "disabled:pointer-events-none disabled:opacity-40",
          
          // Variants
          variant === "default" && [
            "border-border bg-background-surface text-foreground-muted",
            "hover:border-border hover:bg-background-glass hover:text-foreground",
          ],
          variant === "primary" && [
            "border-primary/50 bg-primary text-primary-foreground",
            "hover:bg-primary-glow hover:border-primary",
            "shadow-glow",
          ],
          variant === "ghost" && [
            "border-transparent bg-transparent text-foreground-muted",
            "hover:bg-background-surface hover:text-foreground",
          ],
          
          // Sizes
          size === "sm" && "h-8 px-3",
          size === "md" && "h-9 px-4",
          
          className
        )}
      >
        {icon && <span className="flex-shrink-0">{icon}</span>}
        {children}
      </motion.button>
    );
  }
);

ControlButton.displayName = "ControlButton";
