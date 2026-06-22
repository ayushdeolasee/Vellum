import { Moon, Sun } from "lucide-react";
import { useThemeStore } from "@/stores/theme-store";
import { IconButton } from "@/components/ui/IconButton";

/** Toolbar control that flips between the light and dark Scriptorium themes. */
export function ThemeToggle() {
  const theme = useThemeStore((s) => s.theme);
  const toggleTheme = useThemeStore((s) => s.toggleTheme);
  const isDark = theme === "dark";

  return (
    <IconButton
      onClick={toggleTheme}
      title={isDark ? "Switch to light theme" : "Switch to dark theme"}
      aria-label={isDark ? "Switch to light theme" : "Switch to dark theme"}
    >
      {isDark ? <Sun size={16} /> : <Moon size={16} />}
    </IconButton>
  );
}
