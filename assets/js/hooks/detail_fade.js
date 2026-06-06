/**
 * DetailFade — cross-fades the detail pane when the selected plan changes.
 *
 * Mount on the desktop detail pane container:
 *
 *   <div id="desktop-detail"
 *        phx-hook="DetailFade"
 *        class="plan-detail-pane">
 *
 * When a new plan is selected the LiveView patches the assigns. This hook
 * adds `.loading` (opacity: 0) before the DOM update and removes it after,
 * letting the CSS transition handle the fade-out → fade-in.
 *
 * The `this.el.offsetHeight` read forces a reflow so the browser registers
 * the opacity change before we remove the class — without it the transition
 * is skipped entirely.
 *
 * CSS (app.css §G):
 *   .detail-pane-content { transition: opacity 150ms ease; }
 *   .detail-pane-content.loading { opacity: 0; }
 *
 * Spec: workspaces/plans/.../master-detail/master-detail-spec.md §B
 */
export const DetailFade = {
  beforeUpdate() {
    this.el.classList.add("loading")
  },
  updated() {
    this.el.offsetHeight // force reflow
    this.el.classList.remove("loading")
  }
}
