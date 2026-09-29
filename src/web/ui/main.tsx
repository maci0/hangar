import { render } from "preact";
import { ThemeToggle } from "@/components/theme-toggle";

const existing = document.querySelector(".theme-toggle-btn");
if (existing) {
  const mount = document.createElement("span");
  mount.className = "contents";
  existing.replaceWith(mount);
  render(<ThemeToggle />, mount);
}
