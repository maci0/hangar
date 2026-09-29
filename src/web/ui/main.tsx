import { render } from "preact";
import { ThemeToggle } from "@/components/theme-toggle";
import { VmList, type VmListProps } from "@/components/vm-list";

declare global {
  // Bridge for the legacy app.js, which computes row data and hands it over for rendering.
  var hangarUi: { readonly renderVmList: (props: VmListProps) => void } | undefined;
  var renderList: (() => void) | undefined;
}

const existing = document.querySelector(".theme-toggle-btn");
if (existing) {
  const mount = document.createElement("span");
  mount.className = "contents";
  existing.replaceWith(mount);
  render(<ThemeToggle />, mount);
}

globalThis.hangarUi = {
  renderVmList: (props) => {
    const list = document.querySelector("#vmlist");
    if (list) {
      render(<VmList {...props} />, list);
    }
  },
};
// Rows drawn before this bundle loaded were skipped; draw them now.
globalThis.renderList?.();
