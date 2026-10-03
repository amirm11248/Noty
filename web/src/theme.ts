import { useEffect, useState } from "react";
export type Appearance = "dark" | "light" | "system";
export function useWorkspaceTheme() {
  const [appearance, setAppearance] = useState<Appearance>(() => {
    const saved = localStorage.getItem("noty-appearance");
    return saved === "light" || saved === "system" ? saved : "dark";
  });
  useEffect(() => {
    const system = window.matchMedia("(prefers-color-scheme: dark)");
    const apply = () => {
      document.documentElement.dataset.theme = appearance === "system" ? (system.matches ? "dark" : "light") : appearance;
      document.querySelector('meta[name="theme-color"]')?.setAttribute("content", document.documentElement.dataset.theme === "dark" ? "#161616" : "#fcfcfc");
    };
    localStorage.setItem("noty-appearance", appearance);
    apply();
    system.addEventListener("change", apply);
    return () => system.removeEventListener("change", apply);
  }, [appearance]);
  return [appearance, setAppearance] as const;
}
