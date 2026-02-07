import { motion } from "framer-motion";
import { cn } from "@/lib/utils";

interface StatusIndicatorProps {
  status: "on" | "off" | "loading";
  label?: string;
  className?: string;
}

export const StatusIndicator = ({ status, label, className }: StatusIndicatorProps) => {
  return (
    <div className={cn("flex items-center gap-2.5", className)}>
      <div className="relative flex items-center justify-center">
        {/* Outer glow ring */}
        {status === "on" && (
          <motion.div
            className="absolute inset-0 rounded-full bg-success/30"
            initial={{ scale: 1, opacity: 0.6 }}
            animate={{ scale: 1.8, opacity: 0 }}
            transition={{ duration: 2, repeat: Infinity, ease: "easeOut" }}
          />
        )}
        
        {/* Main indicator dot */}
        <motion.div
          className={cn(
            "relative h-2.5 w-2.5 rounded-full",
            status === "on" && "bg-success shadow-success",
            status === "off" && "bg-foreground-subtle",
            status === "loading" && "bg-warning"
          )}
          animate={status === "loading" ? { opacity: [1, 0.4, 1] } : {}}
          transition={{ duration: 1.5, repeat: Infinity }}
        />
      </div>
      
      {label && (
        <span className="font-mono text-xs font-medium tracking-wide uppercase">
          <span className={cn(
            status === "on" && "text-success",
            status === "off" && "text-foreground-subtle",
            status === "loading" && "text-warning"
          )}>
            {label}
          </span>
        </span>
      )}
    </div>
  );
};
